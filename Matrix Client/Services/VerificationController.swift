import Foundation
import Combine
import MatrixRustSDK

/// Wraps the SDK's `SessionVerificationController` in a simple state machine that drives
/// the verification sheet. Supports both directions: another already-verified device
/// initiating verification of this one, or this device initiating verification of itself
/// (which another verified device must approve).
@MainActor
final class VerificationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case incomingRequest(senderId: String, deviceId: String, deviceName: String?)
        case acknowledged
        case sasStarting
        case emojis(items: [Emoji])
        case finished
        case cancelled(reason: String?)
        case failed(reason: String?)
    }

    struct Emoji: Equatable, Hashable {
        let symbol: String
        let description: String
    }

    @Published private(set) var phase: Phase = .idle

    /// Set true when the SDK pushes an incoming request and we need the UI to react.
    @Published var presented: Bool = false

    private let controller: SessionVerificationController
    private let encryption: Encryption?
    private var delegate: Box?

    init(controller: SessionVerificationController, encryption: Encryption? = nil) {
        self.controller = controller
        self.encryption = encryption
        let box = Box(owner: self)
        self.delegate = box
        controller.setDelegate(delegate: box)
    }

    deinit {
        controller.setDelegate(delegate: nil)
    }

    // MARK: - User-initiated actions

    /// "Verify this device" from this app. Element on the user's other device will get a
    /// prompt to accept.
    func requestVerification() async {
        // Cancel any stale verification that Element Desktop might still hold.
        // Without this, Element sees a "new request while another is ongoing"
        // and cancels BOTH, corrupting the SAS state.
        do {
            try await controller.cancelVerification()
        } catch {
            // No stale request to cancel — that's fine
        }
        // Give Element Desktop time to process the cancellation before we send
        // a new request. Without this delay the new request races with the cancel
        // and Element sees both as concurrent.
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
        do {
            try await controller.requestDeviceVerification()
        } catch {
            phase = .failed(reason: describe(error))
        }
    }

    /// Accept an incoming verification request. The SDK will handle the SAS
    /// transition internally — we just need to accept and wait.
    func acceptIncoming() async {
        guard case .incomingRequest(let senderId, _, _) = phase else { return }
        guard let flowId = lastFlowId else {
            return
        }
        do {
            try await controller.acknowledgeVerificationRequest(senderId: senderId, flowId: flowId)
            try await controller.acceptVerificationRequest()
            // Do NOT call startSasVerification() here. The Rust SDK's internal
            // request-state listener handles the SAS transition automatically
            // (via the Transitioned state). Element X iOS also does not call it.
            phase = .acknowledged
        } catch {
            phase = .failed(reason: describe(error))
        }
    }

    /// Confirm "the emojis match on both sides".
    func confirmMatch() async {
        // Diagnostic: log verification and recovery state before approving
        if let enc = encryption {
            let verState = enc.verificationState()
            let recovState = enc.recoveryState()
        } else {
        }
        do {
            try await controller.approveVerification()
            // Don't change phase here. The delegate will move us to .finished
            // or .cancelled once the other side responds.
        } catch {
            phase = .failed(reason: describe(error))
        }
    }

    /// "Emojis don't match" — reject the SAS comparison.
    func declineMatch() async {
        do {
            try await controller.declineVerification()
        } catch {
            phase = .failed(reason: describe(error))
        }
    }

    /// Cancel the whole flow.
    func cancel() async {
        do {
            try await controller.cancelVerification()
        } catch {
            // Even on failure, return to idle locally so the UI doesn't hang.
        }
        phase = .idle
        presented = false
    }

    /// Dismiss a terminal state and return to idle.
    func dismiss() {
        phase = .idle
        presented = false
        lastFlowId = nil
    }

    // MARK: - Delegate plumbing

    private var lastFlowId: String?

    fileprivate func received(_ details: SessionVerificationRequestDetails) {
        lastFlowId = details.flowId
        phase = .incomingRequest(
            senderId: details.senderProfile.userId,
            deviceId: details.deviceId,
            deviceName: details.deviceDisplayName
        )
        presented = true
    }

    fileprivate func acceptedRequest() {
        // The other device accepted our request. We are the initiator — we do NOT call
        // startSasVerification here. The receiver (other device) will send the SAS start
        // message, and we'll get didStartSasVerification when it arrives.
        phase = .acknowledged
    }

    fileprivate func sasStarted() {
        phase = .sasStarting
    }

    fileprivate func emojisReceived(_ data: SessionVerificationData) {
        switch data {
        case .emojis(let raw, _):
            let mapped = raw.map { Emoji(symbol: $0.symbol(), description: $0.description()) }
            phase = .emojis(items: mapped)
        case .decimals(let values):
            let mapped = values.map { Emoji(symbol: "\($0)", description: "Code") }
            phase = .emojis(items: mapped)
        }
    }

    fileprivate func failed() {
        phase = .failed(reason: nil)
    }

    fileprivate func cancelledByOther() {
        phase = .cancelled(reason: nil)
    }

    fileprivate func finishedSuccessfully() {
        phase = .finished
    }

    // MARK: - Sendable callback box

    final class Box: SessionVerificationControllerDelegate, @unchecked Sendable {
        weak var owner: VerificationController?
        init(owner: VerificationController) { self.owner = owner }

        func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
            Task { @MainActor in self.owner?.received(details) }
        }
        func didAcceptVerificationRequest() {
            Task { @MainActor in self.owner?.acceptedRequest() }
        }
        func didStartSasVerification() {
            Task { @MainActor in self.owner?.sasStarted() }
        }
        func didReceiveVerificationData(data: SessionVerificationData) {
            Task { @MainActor in self.owner?.emojisReceived(data) }
        }
        func didFail() {
            Task { @MainActor in self.owner?.failed() }
        }
        func didCancel() {
            Task { @MainActor in self.owner?.cancelledByOther() }
        }
        func didFinish() {
            Task { @MainActor in self.owner?.finishedSuccessfully() }
        }
    }
}
