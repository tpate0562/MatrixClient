import Foundation

enum MatrixAPIError: Error, LocalizedError {
    case invalidURL
    case http(status: Int, errcode: String?, error: String?)
    case decoding(String)
    case noCredentials
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .http(let s, let c, let e): return "HTTP \(s) — \(c ?? "?"): \(e ?? "")"
        case .decoding(let m): return "Decode error: \(m)"
        case .noCredentials: return "Not logged in"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Thin REST client. Stateless except for the homeserver URL and bearer token.
/// All endpoints follow Client-Server API v3.
actor MatrixAPI {
    private let session: URLSession
    private(set) var homeserverURL: URL?
    private(set) var accessToken: String?

    init(homeserverURL: URL? = nil, accessToken: String? = nil) {
        self.homeserverURL = homeserverURL
        self.accessToken = accessToken
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    func setHomeserver(_ url: URL) { self.homeserverURL = url }
    func setToken(_ token: String?) { self.accessToken = token }

    // MARK: - Server discovery

    /// Resolve a server name (like "matrix.org") to its actual API base URL via /.well-known.
    func discoverHomeserver(from input: String) async throws -> URL {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw MatrixAPIError.invalidURL }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { throw MatrixAPIError.invalidURL }
        let wellKnown = url.appendingPathComponent(".well-known/matrix/client")
        var req = URLRequest(url: wellKnown)
        req.timeoutInterval = 10
        if let (data, resp) = try? await session.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let obj = try? JSONDecoder().decode(LoginResponse.WellKnown.self, from: data),
           let base = obj.homeserver?.base_url, let resolved = URL(string: base) {
            return resolved
        }
        return url
    }

    // MARK: - Auth

    func login(homeserver: URL, user: String, password: String) async throws -> Credentials {
        self.homeserverURL = homeserver
        let body: [String: Any] = [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": user],
            "password": password,
            "initial_device_display_name": "Matrix Client (macOS)"
        ]
        let json = try await postJSON(path: "/_matrix/client/v3/login", body: body, auth: false)
        let resp = try decode(json, as: LoginResponse.self)
        if let base = resp.well_known?.homeserver?.base_url, let resolved = URL(string: base) {
            self.homeserverURL = resolved
        }
        self.accessToken = resp.access_token
        return Credentials(
            homeserverURL: homeserverURL!,
            userId: resp.user_id,
            deviceId: resp.device_id,
            accessToken: resp.access_token
        )
    }

    func logout() async throws {
        _ = try? await postJSON(path: "/_matrix/client/v3/logout", body: [:])
        self.accessToken = nil
    }

    func whoami() async throws -> WhoamiResponse {
        let json = try await getJSON(path: "/_matrix/client/v3/account/whoami")
        return try decode(json, as: WhoamiResponse.self)
    }

    // MARK: - Sync

    func sync(since: String?, timeout: Int = 30000, fullState: Bool = false) async throws -> SyncResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "timeout", value: String(timeout)),
        ]
        if let since { items.append(URLQueryItem(name: "since", value: since)) }
        if fullState { items.append(URLQueryItem(name: "full_state", value: "true")) }
        let json = try await getJSON(path: "/_matrix/client/v3/sync", query: items, timeoutOverride: TimeInterval(timeout) / 1000.0 + 30)
        guard let parsed = SyncResponse.parse(json) else {
            throw MatrixAPIError.decoding("Could not parse sync response")
        }
        return parsed
    }

    // MARK: - Messaging

    /// Send a message event. Returns the new event id.
    @discardableResult
    func sendEvent(roomId: String, type: String, content: [String: Any]) async throws -> String {
        let txnId = "m\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/send/\(encode(type))/\(txnId)"
        let json = try await putJSON(path: path, body: content)
        let resp = try decode(json, as: EventSentResponse.self)
        return resp.event_id
    }

    @discardableResult
    func sendMessage(roomId: String, text: String) async throws -> String {
        try await sendEvent(roomId: roomId, type: "m.room.message", content: [
            "msgtype": "m.text", "body": text
        ])
    }

    @discardableResult
    func sendReaction(roomId: String, targetEventId: String, key: String) async throws -> String {
        try await sendEvent(roomId: roomId, type: "m.reaction", content: [
            "m.relates_to": [
                "rel_type": "m.annotation",
                "event_id": targetEventId,
                "key": key
            ]
        ])
    }

    @discardableResult
    func redact(roomId: String, eventId: String, reason: String? = nil) async throws -> String {
        let txnId = "r\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/redact/\(encode(eventId))/\(txnId)"
        var body: [String: Any] = [:]
        if let reason { body["reason"] = reason }
        let json = try await putJSON(path: path, body: body)
        return try decode(json, as: EventSentResponse.self).event_id
    }

    // MARK: - State

    func setState(roomId: String, type: String, stateKey: String = "", content: [String: Any]) async throws -> String {
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/state/\(encode(type))/\(encode(stateKey))"
        let json = try await putJSON(path: path, body: content)
        return try decode(json, as: EventSentResponse.self).event_id
    }

    func getState(roomId: String, type: String, stateKey: String = "") async throws -> JSONValue {
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/state/\(encode(type))/\(encode(stateKey))"
        return try await getJSON(path: path)
    }

    func members(roomId: String) async throws -> [MatrixEvent] {
        let json = try await getJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/members")
        return (json["chunk"]?.arrayValue ?? []).compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
    }

    // MARK: - Rooms

    func createRoom(name: String?, topic: String?, isDirect: Bool, invite: [String], encrypted: Bool, preset: String) async throws -> String {
        var body: [String: Any] = [
            "preset": preset,
            "is_direct": isDirect,
            "invite": invite
        ]
        if let name { body["name"] = name }
        if let topic { body["topic"] = topic }
        if encrypted {
            body["initial_state"] = [[
                "type": "m.room.encryption",
                "state_key": "",
                "content": ["algorithm": "m.megolm.v1.aes-sha2"]
            ]]
        }
        let json = try await postJSON(path: "/_matrix/client/v3/createRoom", body: body)
        return try decode(json, as: CreateRoomResponse.self).room_id
    }

    func joinRoom(_ identifier: String) async throws -> String {
        let json = try await postJSON(path: "/_matrix/client/v3/join/\(encode(identifier))", body: [:])
        return try decode(json, as: CreateRoomResponse.self).room_id
    }

    func leaveRoom(_ roomId: String) async throws {
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/leave", body: [:])
    }

    func forgetRoom(_ roomId: String) async throws {
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/forget", body: [:])
    }

    func invite(roomId: String, userId: String) async throws {
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/invite",
                               body: ["user_id": userId])
    }

    func kick(roomId: String, userId: String, reason: String?) async throws {
        var body: [String: Any] = ["user_id": userId]
        if let reason { body["reason"] = reason }
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/kick", body: body)
    }

    func ban(roomId: String, userId: String, reason: String?) async throws {
        var body: [String: Any] = ["user_id": userId]
        if let reason { body["reason"] = reason }
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/ban", body: body)
    }

    func unban(roomId: String, userId: String) async throws {
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/unban",
                               body: ["user_id": userId])
    }

    func setTyping(roomId: String, userId: String, typing: Bool, timeout: Int = 20000) async throws {
        var body: [String: Any] = ["typing": typing]
        if typing { body["timeout"] = timeout }
        _ = try await putJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/typing/\(encode(userId))",
                              body: body)
    }

    func sendReadReceipt(roomId: String, eventId: String) async throws {
        _ = try await postJSON(path: "/_matrix/client/v3/rooms/\(encode(roomId))/receipt/m.read/\(encode(eventId))", body: [:])
    }

    // MARK: - Profile / media

    func setDisplayName(userId: String, name: String) async throws {
        _ = try await putJSON(path: "/_matrix/client/v3/profile/\(encode(userId))/displayname",
                              body: ["displayname": name])
    }

    func getDisplayName(userId: String) async throws -> String? {
        let json = try await getJSON(path: "/_matrix/client/v3/profile/\(encode(userId))/displayname")
        return json["displayname"]?.stringValue
    }

    /// Translate an `mxc://` URI to a thumbnail HTTP URL on this server.
    nonisolated func thumbnailURL(homeserver: URL, mxc: String, size: Int = 96) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let trimmed = String(mxc.dropFirst("mxc://".count))
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var c = URLComponents(url: homeserver, resolvingAgainstBaseURL: false)!
        c.path = "/_matrix/media/v3/thumbnail/\(parts[0])/\(parts[1])"
        c.queryItems = [
            URLQueryItem(name: "width", value: String(size)),
            URLQueryItem(name: "height", value: String(size)),
            URLQueryItem(name: "method", value: "crop"),
        ]
        return c.url
    }

    // MARK: - Plumbing

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? component
    }

    private func buildURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = homeserverURL else { throw MatrixAPIError.invalidURL }
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw MatrixAPIError.invalidURL
        }
        c.path = path
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw MatrixAPIError.invalidURL }
        return u
    }

    private func getJSON(path: String, query: [URLQueryItem] = [], timeoutOverride: TimeInterval? = nil) async throws -> JSONValue {
        let url = try buildURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let t = timeoutOverride { req.timeoutInterval = t }
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(req)
    }

    private func postJSON(path: String, body: [String: Any], auth: Bool = true) async throws -> JSONValue {
        try await sendJSON(method: "POST", path: path, body: body, auth: auth)
    }

    private func putJSON(path: String, body: [String: Any], auth: Bool = true) async throws -> JSONValue {
        try await sendJSON(method: "PUT", path: path, body: body, auth: auth)
    }

    private func sendJSON(method: String, path: String, body: [String: Any], auth: Bool) async throws -> JSONValue {
        let url = try buildURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await perform(req)
    }

    private func perform(_ req: URLRequest) async throws -> JSONValue {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixAPIError.http(status: -1, errcode: nil, error: "no response")
        }
        let json: JSONValue
        if data.isEmpty {
            json = .object([:])
        } else {
            do { json = try JSONDecoder().decode(JSONValue.self, from: data) }
            catch { throw MatrixAPIError.decoding(String(describing: error)) }
        }
        if http.statusCode >= 400 {
            throw MatrixAPIError.http(
                status: http.statusCode,
                errcode: json["errcode"]?.stringValue,
                error: json["error"]?.stringValue
            )
        }
        return json
    }

    private func decode<T: Decodable>(_ json: JSONValue, as: T.Type) throws -> T {
        let data = try JSONEncoder().encode(json)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MatrixAPIError.decoding(String(describing: error)) }
    }
}
