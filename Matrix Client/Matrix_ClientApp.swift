import SwiftUI

@main
struct Matrix_ClientApp: App {
    @StateObject private var session = MatrixSession()
    @StateObject private var nicknames = NicknameStore()
    @StateObject private var gate = BiometricGate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(nicknames)
                .environmentObject(gate)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { gate.refreshState() }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // File ▸ Sign Out (replaces the sidebar toolbar button)
            CommandGroup(after: .newItem) {
                Divider()
                Button("Sign Out") {
                    Task { await session.logout() }
                }
                .keyboardShortcut("Q", modifiers: [.command, .shift])
                .disabled(!session.isAuthenticated)
            }
        }

        Settings {
            Text("Matrix Client").padding()
        }
    }
}
