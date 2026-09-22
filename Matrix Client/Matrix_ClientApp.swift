    import SwiftUI
import MatrixRustSDK

@main
struct Matrix_ClientApp: App {
    @StateObject private var session = MatrixSession()
    @StateObject private var nicknames = NicknameStore()
    @StateObject private var reactionHistory = ReactionHistoryStore()
    @StateObject private var gate = BiometricGate()
    @StateObject private var mcpServer = MCPServer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let config = TracingConfiguration(
            logLevel: .error,
            traceLogPacks: [],
            extraTargets: [],
            writeToStdoutOrSystem: true,
            writeToFiles: nil,
            sentryConfig: nil
        )
        try? initPlatform(config: config, useLightweightTokioRuntime: false)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(nicknames)
                .environmentObject(reactionHistory)
                .environmentObject(gate)
                .environmentObject(mcpServer)
                .onAppear {
                    mcpServer.attach(session: session)
                    if mcpServer.autoStart { mcpServer.start() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { gate.refreshState() }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // File ▸ Repull / Sign Out (replace the sidebar toolbar buttons)
            CommandGroup(after: .newItem) {
                Divider()
                Button("Repull All History & Media") {
                    Task { await session.repullAllHistoryAndMedia() }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(!session.isAuthenticated || session.repullInProgress)
                Divider()
                Button("Sign Out") {
                    Task { await session.logout() }
                }
                .keyboardShortcut("Q", modifiers: [.command, .shift])
                .disabled(!session.isAuthenticated)
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(mcpServer)
                .environmentObject(gate)
        }
    }
}
