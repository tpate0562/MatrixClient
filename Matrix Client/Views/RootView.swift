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
            // Progress for a File ▸ Repull All History & Media run. Sits above the
            // chat but below the lock cover.
            if session.isAuthenticated && session.repullInProgress {
                VStack {
                    RepullBanner()
                    Spacer()
                }
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
                    Label("Unlock", systemImage: "lock.open.fill")
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

private struct RepullBanner: View {
    @EnvironmentObject private var session: MatrixSession

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Repulling history & media…")
                    .font(.callout.weight(.medium))
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if session.repullTotal > 0 {
                ProgressView(value: Double(session.repullDone),
                             total: Double(session.repullTotal))
                    .frame(width: 120)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.top, 10)
    }

    private var statusLine: String {
        let total = session.repullTotal
        let done = session.repullDone
        let current = session.repullCurrentRoom
        if !current.isEmpty {
            return "\(current) — room \(min(done + 1, total)) of \(total)"
        }
        return "\(done) of \(total) rooms"
    }
}
