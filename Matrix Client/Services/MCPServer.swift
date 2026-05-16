import AppKit
import Foundation
import Network
import Combine

/// Local MCP (Model Context Protocol) server. Listens on 127.0.0.1, speaks JSON-RPC 2.0
/// over the MCP "Streamable HTTP" transport, and dispatches `tools/call` requests to
/// `MCPTools` which in turn drives `MatrixSession` / `RoomVM`.
///
/// Connections are loopback-only and require a Bearer token (regenerated on demand from
/// the settings UI). The server defaults to port 8765 and is opt-in via the settings UI.
@MainActor
final class MCPServer: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = 8765
    @Published private(set) var token: String = ""
    @Published private(set) var requestCount: Int = 0
    @Published private(set) var recentRequests: [String] = []
    @Published var autoStart: Bool = false
    @Published var lastError: String?
    @Published private(set) var useHTTPS: Bool = false

    weak var session: MatrixSession?

    /// Cached TLS identity. Loaded lazily the first time the server starts with HTTPS on.
    private var tlsIdentity: SecIdentity?

    nonisolated private let queue = DispatchQueue(label: "matrix-mcp")
    private var listener: NWListener?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "mcpToken"), !saved.isEmpty {
            self.token = saved
        } else {
            let new = Self.generateToken()
            defaults.set(new, forKey: "mcpToken")
            self.token = new
        }
        let savedPort = defaults.integer(forKey: "mcpPort")
        if savedPort > 0 && savedPort < 65536 {
            self.port = UInt16(savedPort)
        }
        self.autoStart = defaults.bool(forKey: "mcpAutoStart")
        self.useHTTPS = defaults.bool(forKey: "mcpUseHTTPS")
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func regenerateToken() {
        let new = Self.generateToken()
        UserDefaults.standard.set(new, forKey: "mcpToken")
        self.token = new
    }

    func setPort(_ newPort: UInt16) async {
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: "mcpPort")
        if wasRunning { start() }
    }

    func setAutoStart(_ on: Bool) {
        self.autoStart = on
        UserDefaults.standard.set(on, forKey: "mcpAutoStart")
    }

    func setHTTPS(_ on: Bool) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        useHTTPS = on
        if !on { tlsIdentity = nil }
        UserDefaults.standard.set(on, forKey: "mcpUseHTTPS")
        if wasRunning { start() }
    }

    /// Exports the TLS certificate to a temp `.cer` file and opens it in Keychain
    /// Access so the user can mark it as trusted.
    func openCertForTrust() {
        let identity: SecIdentity?
        if let cached = tlsIdentity {
            identity = cached
        } else {
            identity = try? MCPTLSHelper.getOrCreateIdentity()
        }
        guard let id = identity,
              let url = MCPTLSHelper.exportCertToTemp(identity: id) else { return }
        NSWorkspace.shared.open(url)
    }

    func attach(session: MatrixSession) {
        self.session = session
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid port: \(port)"
            return
        }
        do {
            let params: NWParameters
            if useHTTPS {
                // Load (or generate) the TLS identity on first use.
                if tlsIdentity == nil {
                    do {
                        tlsIdentity = try MCPTLSHelper.getOrCreateIdentity()
                    } catch {
                        lastError = "TLS setup failed: \(error.localizedDescription)"
                        return
                    }
                }
                let tlsOpts = NWProtocolTLS.Options()
                if let secId = sec_identity_create(tlsIdentity!) {
                    sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, secId)
                }
                // Don't require a client certificate.
                sec_protocol_options_set_peer_authentication_required(
                    tlsOpts.securityProtocolOptions, false)
                params = NWParameters(tls: tlsOpts)
            } else {
                params = NWParameters.tcp
            }
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true
            let listener = try NWListener(using: params, on: nwPort)
            let server = self
            listener.newConnectionHandler = { connection in
                MCPServer.handleNewConnection(connection, server: server)
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        server.isRunning = true
                        server.lastError = nil
                    case .failed(let error):
                        server.isRunning = false
                        server.lastError = "Listener failed: \(error.localizedDescription)"
                        server.listener = nil
                    case .cancelled:
                        server.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = "Start failed: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling (non-isolated; runs on `queue`)

    nonisolated private static func handleNewConnection(_ connection: NWConnection, server: MCPServer) {
        connection.start(queue: server.queue)
        readRequest(connection: connection, accumulated: Data(), server: server)
    }

    nonisolated private static func readRequest(connection: NWConnection, accumulated: Data, server: MCPServer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data = data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            if let request = HTTPRequest.parse(buffer) {
                Task {
                    let response = await server.handleHTTPRequest(request)
                    connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            } else if isComplete {
                connection.cancel()
            } else if buffer.count < 4 * 1024 * 1024 {
                readRequest(connection: connection, accumulated: buffer, server: server)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - Request handling (MainActor)

    fileprivate func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        recordRequest(request)

        // CORS preflight — some MCP clients send these.
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, statusText: "No Content", headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id",
            ], body: Data())
        }

        // Status page on GET / (useful for sanity-checking from a browser).
        if request.method == "GET" && (request.path == "/" || request.path == "/status") {
            let body = "Matrix Client MCP server\nstatus: running\nport: \(port)\nMCP endpoint: POST /mcp\n"
            return HTTPResponse(status: 200, statusText: "OK", headers: [
                "Content-Type": "text/plain; charset=utf-8",
            ], body: Data(body.utf8))
        }

        // Bearer-token auth for everything except the public status page.
        let authHeader = request.headers["authorization"] ?? ""
        let expected = "Bearer \(token)"
        guard authHeader == expected else {
            return HTTPResponse.json(["error": "unauthorized"], status: 401)
        }

        // The MCP "Streamable HTTP" endpoint accepts POST (request) and GET (open SSE
        // stream). We don't push notifications, so GET returns an empty SSE response.
        if request.method == "GET" && request.path == "/mcp" {
            return HTTPResponse(status: 200, statusText: "OK", headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "close",
            ], body: Data())
        }

        guard request.method == "POST", request.path == "/mcp" else {
            return HTTPResponse.json(["error": "not found"], status: 404)
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            return HTTPResponse.json(["error": "invalid json"], status: 400)
        }

        // Single message or batch (JSON-RPC 2.0 allows arrays).
        if let single = json as? [String: Any] {
            let result = await dispatchRPC(single)
            if let result = result {
                return HTTPResponse.json(result)
            }
            return HTTPResponse(status: 202, statusText: "Accepted", headers: [:], body: Data())
        } else if let batch = json as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for msg in batch {
                if let result = await dispatchRPC(msg) {
                    responses.append(result)
                }
            }
            if responses.isEmpty {
                return HTTPResponse(status: 202, statusText: "Accepted", headers: [:], body: Data())
            }
            return HTTPResponse.json(responses)
        }
        return HTTPResponse.json(["error": "malformed request"], status: 400)
    }

    private func recordRequest(_ request: HTTPRequest) {
        requestCount += 1
        let summary = "\(request.method) \(request.path)"
        recentRequests.append(summary)
        if recentRequests.count > 50 { recentRequests.removeFirst(recentRequests.count - 50) }
    }

    /// Dispatch one JSON-RPC 2.0 message. Returns `nil` for notifications (no response).
    private func dispatchRPC(_ message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let isNotification = id == nil
        guard let method = message["method"] as? String else {
            return isNotification ? nil : jsonRPCError(id: id, code: -32600, message: "Invalid Request")
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            return jsonRPCResult(id: id, result: [
                "protocolVersion": requested,
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": [
                    "name": "matrix-client",
                    "version": "1.0.0",
                ],
                "instructions": "Matrix Client MCP server. Use `list_rooms` to enumerate joined rooms, then `list_messages` or `send_message` with the room_id. All admin tools (invite/kick/ban/power) take a room_id + user_id.",
            ])
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil
        case "ping":
            return jsonRPCResult(id: id, result: [:])
        case "tools/list":
            return jsonRPCResult(id: id, result: ["tools": MCPTools.toolDefinitions])
        case "tools/call":
            return await handleToolsCall(id: id, params: params)
        case "resources/list":
            return jsonRPCResult(id: id, result: ["resources": []])
        case "resources/templates/list":
            return jsonRPCResult(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return jsonRPCResult(id: id, result: ["prompts": []])
        default:
            return isNotification ? nil : jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) async -> [String: Any] {
        guard let name = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let session = session else {
            return jsonRPCResult(id: id, result: MCPTools.errorContent("Not signed in"))
        }
        do {
            let content = try await MCPTools.execute(name: name, arguments: args, session: session)
            return jsonRPCResult(id: id, result: content)
        } catch let error as MCPToolError {
            return jsonRPCResult(id: id, result: MCPTools.errorContent(error.message))
        } catch {
            return jsonRPCResult(id: id, result: MCPTools.errorContent(describe(error)))
        }
    }

    private func jsonRPCResult(id: Any?, result: Any) -> [String: Any] {
        var dict: [String: Any] = ["jsonrpc": "2.0", "result": result]
        dict["id"] = id ?? NSNull()
        return dict
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> [String: Any] {
        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        dict["id"] = id ?? NSNull()
        return dict
    }
}

// MARK: - Tool errors

nonisolated struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Tiny HTTP/1.1 parser + serializer

nonisolated struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns a fully-parsed request once enough bytes have arrived (headers + body),
    /// otherwise `nil` (the caller should keep accumulating).
    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: 0..<sepRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = sepRange.upperBound
        let expectedLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if available < expectedLength { return nil }
        let body = expectedLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + expectedLength))
            : Data()
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

nonisolated struct HTTPResponse: Sendable {
    let status: Int
    let statusText: String
    let headers: [String: String]
    let body: Data

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data()
        return HTTPResponse(
            status: status,
            statusText: statusText(for: status),
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var hdr = headers
        hdr["Content-Length"] = "\(body.count)"
        hdr["Connection"] = "close"
        hdr["Access-Control-Allow-Origin"] = hdr["Access-Control-Allow-Origin"] ?? "*"
        for (k, v) in hdr { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
