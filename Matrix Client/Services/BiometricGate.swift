import Foundation
import Combine
import LocalAuthentication

/// Locks the UI behind biometric auth (Touch ID / device password). The gate stays unlocked
/// for an hour after a successful unlock — coming back inside that window doesn't re-prompt.
@MainActor
final class BiometricGate: ObservableObject {
    @Published private(set) var isUnlocked: Bool = false
    @Published var authError: String?

    private let lastUnlockKey = "matrixClient.lastUnlockTimestamp"
    private let interval: TimeInterval = 3600   // 1 hour

    init() {
        refreshState()
    }

    /// Re-evaluate whether we're inside the grace period. Call on launch + when the app
    /// comes back from background.
    func refreshState() {
        let last = UserDefaults.standard.double(forKey: lastUnlockKey)
        guard last > 0 else { isUnlocked = false; return }
        isUnlocked = Date().timeIntervalSince1970 - last < interval
    }

    /// Prompt for Touch ID. Falls back to device password if biometrics aren't available.
    func unlock() async {
        authError = nil
        let ctx = LAContext()
        ctx.localizedReason = "Unlock Matrix Client"

        var policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        var err: NSError?
        if !ctx.canEvaluatePolicy(policy, error: &err) {
            policy = .deviceOwnerAuthentication
            if !ctx.canEvaluatePolicy(policy, error: &err) {
                // No auth available — fail open so the user isn't permanently locked out.
                markUnlocked()
                return
            }
        }
        do {
            let ok = try await ctx.evaluatePolicy(policy, localizedReason: "Unlock Matrix Client")
            if ok { markUnlocked() }
        } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func markUnlocked() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUnlockKey)
        isUnlocked = true
        authError = nil
    }
}
