import Foundation
import Combine
import AppKit
import LocalAuthentication

/// Locks the UI behind biometric auth (Touch ID / device password).
///
/// Enforcement: the app locks the instant it loses focus (the user switches to
/// another app), and requires Touch ID again when it returns. The 1-hour grace
/// window only suppresses re-prompts during *continuous foreground use* — it
/// never bridges a focus loss, because losing focus clears the timestamp.
@MainActor
final class BiometricGate: ObservableObject {
    @Published private(set) var isUnlocked: Bool = false
    @Published var authError: String?

    private let lastUnlockKey = "matrixClient.lastUnlockTimestamp"
    private let interval: TimeInterval = 3600   // 1 hour
    private var authInProgress = false
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshState()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        })
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleBecameActive() }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Re-evaluate whether we're inside the grace period. Call on launch + when
    /// the app comes back to the foreground.
    func refreshState() {
        let last = UserDefaults.standard.double(forKey: lastUnlockKey)
        guard last > 0 else { isUnlocked = false; return }
        isUnlocked = Date().timeIntervalSince1970 - last < interval
    }

    /// Lock immediately and drop the grace timestamp so returning to the app
    /// always re-prompts. No-op while an auth prompt is up, so the system Touch
    /// ID sheet (which can briefly resign-active) can't lock us mid-auth.
    func lock() {
        guard !authInProgress else { return }
        UserDefaults.standard.removeObject(forKey: lastUnlockKey)
        isUnlocked = false
        authError = nil
    }

    private func handleBecameActive() {
        refreshState()
        if !isUnlocked { Task { await unlock() } }
    }

    /// Prompt for Touch ID. Falls back to device password if biometrics aren't available.
    func unlock() async {
        // Don't stack prompts, and don't prompt while we're not the active app
        // (e.g. LockScreen's auto-trigger firing while still in the background).
        guard !authInProgress, NSApplication.shared.isActive else { return }
        authInProgress = true
        defer { authInProgress = false }
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
