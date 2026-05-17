import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var gate: BiometricGate

    var body: some View {
        ZStack {
            // Kept mounted while locked so unlocking restores exactly where
            // you were (selected room, scroll, draft) instead of resetting.
            if session.isAuthenticated {
                MainView()
            } else {
                LoginView()
            }
            // Opaque cover — also hides chat content from app-switcher /
            // screenshots while the app is unfocused.
            if !gate.isUnlocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: gate.isUnlocked)
    }
}

private struct LockScreen: View {
    @EnvironmentObject private var gate: BiometricGate

    var body: some View {
        ZStack {
            // Fully opaque so the chat underneath is never visible while locked.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
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
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Auto-prompt on appear so the user doesn't have to click an extra button.
            await gate.unlock()
        }
    }
}
