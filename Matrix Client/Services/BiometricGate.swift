import Foundation
import Combine
import AppKit
import LocalAuthentication

enum LockMode: String, CaseIterable {
    case onFocusLoss = "onFocusLoss"
    case after10Minutes = "after10Minutes"

    var label: String {
        switch self {
        case .onFocusLoss:   return "Every time app loses focus"
        case .after10Minutes: return "After 10 minutes away"
        }
    }
}

/// Locks the UI behind biometric auth (Touch ID / device password).
@MainActor
final class BiometricGate: ObservableObject {
    @Published private(set) var isUnlocked: Bool = false
    @Published var authError: String?

    private let lastUnlockKey = "matrixClient.lastUnlockTimestamp"
    private let lockModeKey   = "matrixClient.lockMode"
    private let tenMinutes: TimeInterval = 600
    private var authInProgress = false
    private var observers: [NSObjectProtocol] = []

    var lockMode: LockMode {
        get {
            let raw = UserDefaults.standard.string(forKey: lockModeKey) ?? ""
            return LockMode(rawValue: raw) ?? .onFocusLoss
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: lockModeKey)
            objectWillChange.send()
        }
    }

    init() {
        refreshState()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleResignActive() }
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

    func refreshState() {
        let last = UserDefaults.standard.double(forKey: lastUnlockKey)
        guard last > 0 else { isUnlocked = false; return }
        switch lockMode {
        case .onFocusLoss:
            // Key is cleared on resign-active; if still present we just launched.
            isUnlocked = Date().timeIntervalSince1970 - last < 5
        case .after10Minutes:
            isUnlocked = Date().timeIntervalSince1970 - last < tenMinutes
        }
    }

    func lock() {
        guard !authInProgress else { return }
        UserDefaults.standard.removeObject(forKey: lastUnlockKey)
        isUnlocked = false
        authError = nil
    }

    private func handleResignActive() {
        switch lockMode {
        case .onFocusLoss:
            lock()
        case .after10Minutes:
            break   // let the grace period decide on next activation
        }
    }

    private func handleBecameActive() {
        refreshState()
        if !isUnlocked { Task { await unlock() } }
    }

    /// Prompt for Touch ID or device password.
    /// Uses `.deviceOwnerAuthentication` so the "Use Password" fallback always works.
    func unlock() async {
        guard !authInProgress, NSApplication.shared.isActive else { return }
        authInProgress = true
        defer { authInProgress = false }
        authError = nil

        let ctx = LAContext()
        ctx.localizedReason = "Unlock Matrix Client"

        let policy = LAPolicy.deviceOwnerAuthentication
        var err: NSError?
        guard ctx.canEvaluatePolicy(policy, error: &err) else {
            markUnlocked()   // no auth available — fail open
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(policy, localizedReason: "Unlock Matrix Client")
            if ok { markUnlocked() }
        } catch let e as LAError
            where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
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
