import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            SecuritySettingsPane()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            ChatSettingsPane()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - Security

private struct SecuritySettingsPane: View {
    @EnvironmentObject private var gate: BiometricGate

    var body: some View {
        Form {
            Section {
                Picker("Require authentication:", selection: Binding(
                    get: { gate.lockMode },
                    set: { gate.lockMode = $0 }
                )) {
                    ForEach(LockMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Lock Behavior")
            } footer: {
                Text("The app always locks when macOS puts the screen to sleep or you log out, regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Chat

private struct ChatSettingsPane: View {
    @AppStorage("leftAlignMessages") private var leftAlignMessages = false

    var body: some View {
        Form {
            Section("Message Layout") {
                Toggle("Left-align all messages (Discord style)", isOn: $leftAlignMessages)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
