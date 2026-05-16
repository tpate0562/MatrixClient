import SwiftUI

/// Settings + status panel for the in-app MCP server. Exposed from the sidebar's
/// "New" menu so the user can flip it on, copy the token, regenerate it, etc.
struct MCPSettingsView: View {
    @EnvironmentObject private var server: MCPServer
    @Environment(\.dismiss) private var dismiss

    @State private var portString: String = ""
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    connectionCard
                    quickStartCard
                    cliCard
                    claudeDesktopCard
                    requestLogCard
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 540)
        .onAppear {
            portString = String(server.port)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Server").font(.title2.bold())
                Text("Let Claude (or any MCP client) drive this Matrix client over a local HTTP endpoint.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(server.isRunning ? "Running on \(scheme)://127.0.0.1:\(server.port)" : "Stopped")
                        .font(.headline)
                    Spacer()
                    if server.isRunning {
                        Button("Stop", role: .destructive) { server.stop() }
                    } else {
                        Button("Start") { server.start() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let err = server.lastError, !err.isEmpty {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Start automatically when the app launches",
                       isOn: Binding(
                        get: { server.autoStart },
                        set: { server.setAutoStart($0) }
                       ))
            }
            .padding(4)
        }
    }

    private var scheme: String { server.useHTTPS ? "https" : "http" }
    private var baseURL: String { "\(scheme)://127.0.0.1:\(server.port)/mcp" }

    private var connectionCard: some View {
        GroupBox(label: Label("Connection", systemImage: "network").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 10) {
                // HTTPS toggle
                HStack {
                    Text("Protocol").frame(width: 90, alignment: .leading)
                    Toggle("HTTPS (TLS)", isOn: Binding(
                        get: { server.useHTTPS },
                        set: { server.setHTTPS($0) }
                    ))
                    Spacer()
                }
                if server.useHTTPS {
                    HStack(alignment: .top) {
                        Text("").frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Button("Open Certificate in Keychain Access…") {
                                server.openCertForTrust()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.blue)
                            Text("In Keychain Access: right-click the cert → Get Info → Trust → Always Trust. Then restart Claude Code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                }
                HStack {
                    Text("Port").frame(width: 90, alignment: .leading)
                    TextField("8765", text: $portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("Apply") {
                        if let p = UInt16(portString) {
                            Task { await server.setPort(p) }
                        }
                    }
                    .disabled(UInt16(portString) == server.port)
                    Spacer()
                }
                HStack {
                    Text("URL").frame(width: 90, alignment: .leading)
                    Text(baseURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copy(baseURL)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy URL")
                }
                HStack(alignment: .top) {
                    Text("Token").frame(width: 90, alignment: .leading)
                    Text(server.token)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copy(server.token)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy token")
                    Button("Regenerate") {
                        server.regenerateToken()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Generates a new token. Update Claude Code's config afterward.")
                }
                if showCopied {
                    Text("Copied to clipboard").font(.caption).foregroundStyle(.green)
                }
            }
            .padding(4)
        }
    }

    private var quickStartCard: some View {
        GroupBox(label: Label("Claude Code setup", systemImage: "terminal").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Run this once in any terminal:")
                    .font(.callout)
                claudeCodeCommand
                Text("Then ask Claude to ‘list my Matrix rooms’ or ‘send a message to #room:server’.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Or paste into ~/.claude.json under `mcpServers`:")
                    .font(.callout)
                claudeJSONBlock
            }
            .padding(4)
        }
    }

    private var claudeCodeCommand: some View {
        let cmd = "claude mcp add --transport http --scope user matrix-client \(baseURL) --header \"Authorization: Bearer \(server.token)\""
        return HStack(alignment: .top) {
            Text(cmd)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(6)
            Button {
                copy(cmd)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy command")
        }
    }

    private var claudeJSONBlock: some View {
        let block = """
        {
          "mcpServers": {
            "matrix-client": {
              "type": "http",
              "url": "\(baseURL)",
              "headers": {
                "Authorization": "Bearer \(server.token)"
              }
            }
          }
        }
        """
        return HStack(alignment: .top) {
            Text(block)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(6)
            Button {
                copy(block)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy JSON")
        }
    }

    // MARK: - CLI tool card

    private var cliScript: String {
        """
        #!/usr/bin/env python3
        \"\"\"matrix-client CLI — control the Matrix Client app from the terminal.\"\"\"
        import sys, json, urllib.request, urllib.error

        TOKEN = "\(server.token)"
        URL   = "\(baseURL)"

        def rpc(tool, **args):
            body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                               "params":{"name":tool,"arguments":args}}).encode()
            req = urllib.request.Request(URL, data=body,
                headers={"Content-Type":"application/json",
                         "Authorization":f"Bearer {TOKEN}"}, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=15) as r:
                    data = json.loads(r.read())
                for item in data.get("result",{}).get("content",[]):
                    if item.get("type") == "text":
                        print(item["text"])
            except urllib.error.HTTPError as e:
                print(f"Error {e.code}: {e.read().decode()}", file=sys.stderr)
                sys.exit(1)

        def flag(name, default=None):
            try: return sys.argv[sys.argv.index(name)+1]
            except (ValueError, IndexError): return default

        cmd  = sys.argv[1] if len(sys.argv) > 1 else "help"
        args = [a for a in sys.argv[2:] if not a.startswith("-")]

        if cmd in ("rooms", "list"):
            rpc("list_rooms", filter=flag("-filter",""), limit=int(flag("-limit",50)))
        elif cmd in ("write", "send"):
            rpc("send_message", room_id=args[0], body=flag("-message", " ".join(args[1:])))
        elif cmd in ("read", "messages"):
            rpc("list_messages", room_id=args[0], limit=int(flag("-limit",20)))
        elif cmd == "search":
            rpc("search_messages", room_id=args[0], query=flag("-query", args[1] if len(args)>1 else ""))
        elif cmd == "reply":
            rpc("send_reply", room_id=args[0], event_id=args[1], body=flag("-message",""))
        elif cmd == "whoami":
            rpc("whoami")
        else:
            print(\"\"\"Usage:
          matrix-client rooms [-filter name] [-limit N]
          matrix-client write  <room_id> -message "text"
          matrix-client read   <room_id> [-limit N]
          matrix-client search <room_id> -query "text"
          matrix-client reply  <room_id> <event_id> -message "text"
          matrix-client whoami\"\"\")
        """
    }

    private var cliCard: some View {
        GroupBox(label: Label("CLI Tool", systemImage: "terminal").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A standalone terminal command — no MCP needed. Save it to your PATH and call it directly, or reference it in Claude's custom instructions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top) {
                    Text(cliScript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(6)
                    VStack {
                        Button { copy(cliScript) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy script")
                        Button { saveCLIScript() } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderless).help("Save script…")
                    }
                }

                Text("Install:")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    Text("chmod +x ~/matrix-client && sudo mv ~/matrix-client /usr/local/bin/")
                        .font(.system(.caption, design: .monospaced))
                }
                .foregroundStyle(.secondary)

                Divider()

                Text("Then add to Claude's custom instructions:")
                    .font(.callout)
                let instructions = """
                I have a `matrix-client` CLI that controls the Matrix Client app on my Mac. \
                Use it to send and read Matrix messages. Examples:
                  matrix-client rooms
                  matrix-client write <room_id> -message "hello"
                  matrix-client read <room_id> -limit 20
                  matrix-client search <room_id> -query "keyword"
                  matrix-client whoami
                The app must be running for the command to work.
                """
                HStack(alignment: .top) {
                    Text(instructions)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(6)
                    Button { copy(instructions) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy instructions")
                }
            }
            .padding(4)
        }
    }

    private func saveCLIScript() {
        let script = cliScript
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "matrix-client"
        panel.message = "Save the matrix-client CLI script"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - Claude Desktop / stdio card

    /// Python bridge script tailored to the current token + scheme.
    private var bridgeScript: String {
        let ssl = server.useHTTPS
        let sslImport  = ssl ? ", ssl" : ""
        let sslSetup   = ssl ? "\nctx = ssl.create_default_context()\nctx.check_hostname = False\nctx.verify_mode = ssl.CERT_NONE" : ""
        let ctxArg     = ssl ? ", context=ctx" : ""
        return """
        #!/usr/bin/env python3
        \"\"\"Matrix Client MCP stdio bridge.
        Relay Claude Desktop JSON-RPC stdin ↔ Matrix Client HTTP server.
        Save as ~/matrix-mcp, then: chmod +x ~/matrix-mcp
        \"\"\"
        import sys, json, urllib.request, urllib.error\(sslImport)

        TOKEN = "\(server.token)"
        URL   = "\(baseURL)"\(sslSetup)

        def relay(msg):
            req = urllib.request.Request(
                URL, data=msg.encode(),
                headers={"Content-Type": "application/json",
                         "Authorization": f"Bearer {TOKEN}"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=30\(ctxArg)) as r:
                    body = r.read()
                    return body.decode().strip() if body else None
            except urllib.error.HTTPError as e:
                body = e.read()
                return body.decode().strip() if body else None
            except Exception as e:
                return json.dumps({"jsonrpc":"2.0","error":{"code":-32603,"message":str(e)},"id":None})

        for raw in sys.stdin:
            line = raw.strip()
            if not line: continue
            out = relay(line)
            if out:
                sys.stdout.write(out + "\\n")
                sys.stdout.flush()
        """
    }

    private var claudeDesktopCard: some View {
        GroupBox(label: Label("Claude Desktop / stdio", systemImage: "desktopcomputer").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Claude Desktop uses stdio, not HTTP. Save this Python script (comes pre-filled with your token), make it executable, then point Claude Desktop at it — no HTTPS or ngrok needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Bridge script
                HStack(alignment: .top) {
                    Text(bridgeScript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(6)
                    VStack {
                        Button { copy(bridgeScript) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy script")
                        Button { saveBridgeScript() } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderless)
                            .help("Save script…")
                    }
                }

                Text("After saving:")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1.  chmod +x ~/matrix-mcp")
                        .font(.system(.callout, design: .monospaced))
                    Text("2.  Edit ~/Library/Application Support/Claude/claude_desktop_config.json")
                        .font(.system(.callout, design: .monospaced))
                }
                .foregroundStyle(.secondary)

                // Claude Desktop JSON
                let desktopJSON = """
                {
                  "mcpServers": {
                    "matrix-client": {
                      "command": "\(NSHomeDirectory())/matrix-mcp"
                    }
                  }
                }
                """
                HStack(alignment: .top) {
                    Text(desktopJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(6)
                    Button { copy(desktopJSON) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy JSON")
                }
            }
            .padding(4)
        }
    }

    private func saveBridgeScript() {
        let script = bridgeScript
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "matrix-mcp"
        panel.message = "Save the MCP bridge script — then run: chmod +x <saved path>"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                // Best-effort executable bit; may be silently ignored in sandbox.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.path
                )
            } catch { /* user can use the copy button as fallback */ }
        }
    }

    // MARK: - Request log

    @ViewBuilder
    private var requestLogCard: some View {
        if !server.recentRequests.isEmpty {
            GroupBox(label: Label("Recent requests (\(server.requestCount) total)",
                                  systemImage: "list.bullet.rectangle").font(.subheadline)) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(server.recentRequests.suffix(10).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        showCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopied = false
        }
    }
}
