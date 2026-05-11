import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var gate: BiometricGate

    var body: some View {
        Group {
            if !gate.isUnlocked {
                LockScreen()
            } else if session.isAuthenticated {
                MainView()
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct LockScreen: View {
    @EnvironmentObject private var gate: BiometricGate

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Matrix Client")
                .font(.title.bold())
            Text("Authenticate to continue")
                .foregroundStyle(.secondary)
            if let err = gate.authError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                Task { await gate.unlock() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
                    .frame(maxWidth: 220)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .task {
            // Auto-prompt on appear so the user doesn't have to click an extra button.
            await gate.unlock()
        }
    }
}
