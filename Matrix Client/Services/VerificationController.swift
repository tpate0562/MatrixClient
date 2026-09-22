import Foundation
import Combine
import MatrixRustSDK

/// Wraps the SDK's `SessionVerificationController` in a simple state machine that drives
/// the verification sheet. Supports both directions: another already-verified device
/// initiating verification of this one, or this device initiating verification of itself
/// (which another verified device must approve).
///
/// Threading: the Rust SDK fires delegate callbacks from its own threads, and fires some of
/// them back-to-back — `didStartSasVerification` is immediately followed by
/// `didReceiveVerificationData`. Hopping each callback onto the main actor in its own
/// unstructured `Task` gives no ordering guarantee between those tasks, so the emojis could
/// be applied first and then overwritten by the SAS-start phase, stranding the sheet on
/// "Waiting for the other device…" with no way to confirm. Callbacks are therefore funnelled
/// through a single `AsyncStream` — which hands elements to its consumer in the order they
/// were yielded — and drained by one consumer on the main actor. `apply(_:)` additionally
/// refuses backwards transitions, so a duplicated or late event cannot undo progress.
@MainActor
final class VerificationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case incomingRequest(senderId: String, deviceId: String, deviceName: String?)
        case acknowledged
        case sasStarting
        case emojis(items: [Emoji])
        case approved
        case finished
        case cancelled(reason: String?)
        case failed(reason: String?)
    }

    struct Emoji: Equatable, Hashable {
        let symbol: String
        let description: String
    }

    @Published private(set) var phase: Phase = .idle

    /// True while an SDK call we initiated is in flight. The sheet disables its buttons on
    /// this: two overlapping verification actions corrupt the SAS state on both ends, and a
    /// double tap is otherwise easy because the SDK calls take a moment to come back.
    @Published private(set) var isBusy: Bool = false

    /// Set true when the SDK pushes an incoming request and we need the UI to react.
    @Published var presented: Bool = false

    private let controller: SessionVerificationController
    private let encryption: Encryption?
    private var delegate: Box?
    private var eventTask: Task<Void, Never>?
    private var lastFlowId: String?

    init(controller: SessionVerificationController, encryption: Encryption? = nil) {
        self.controller = controller
        self.encryption = encryption

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let box = Box(continuation: continuation)
        self.delegate = box
        controller.setDelegate(delegate: box)

        // A single consumer, so events land in exactly the order the SDK delivered them.
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    deinit {
        controller.setDelegate(delegate: nil)
    }

    // MARK: - User-initiated actions

    /// "Verify this device" from this app. Element on the user's other device will get a
    /// prompt to accept.
    func requestVerification() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

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
        // An incoming request may have arrived while we slept, in which case that flow is
        // already underway and ours would collide with it.
        guard phase == .idle else { return }
        do {
            try await controller.requestDeviceVerification()
        } catch {
            apply(.failed(reason: describe(error)))
        }
    }

    /// Accept an incoming verification request. The SDK will handle the SAS
    /// transition internally — we just need to accept and wait.
    func acceptIncoming() async {
        guard !isBusy else { return }
        guard case .incomingRequest(let senderId, _, _) = phase else { return }
        guard let flowId = lastFlowId else {
            return
        }
        isBusy = true
        do {
            try await controller.acknowledgeVerificationRequest(senderId: senderId, flowId: flowId)
            try await controller.acceptVerificationRequest()
            // Do NOT call startSasVerification() here. The Rust SDK's internal
            // request-state listener handles the SAS transition automatically
            // (via the Transitioned state). Element X iOS also does not call it.
            apply(.acknowledged)
        } catch {
            isBusy = false
            apply(.failed(reason: describe(error)))
        }
    }

    /// Confirm "the emojis match on both sides".
    func confirmMatch() async {
        guard !isBusy else { return }
        guard case .emojis = phase else { return }
        isBusy = true
        do {
            try await controller.approveVerification()
            // The delegate moves us to .finished or .cancelled once the other side
            // responds; until then this phase keeps the emoji buttons out of reach while
            // still offering Cancel.
            apply(.approved)
        } catch {
            isBusy = false
            apply(.failed(reason: describe(error)))
        }
    }

    /// "Emojis don't match" — reject the SAS comparison.
    func declineMatch() async {
        guard !isBusy else { return }
        guard case .emojis = phase else { return }
        isBusy = true
        do {
            try await controller.declineVerification()
            // The user has already decided; don't sit disabled waiting for the SDK to echo
            // the cancellation back.
            apply(.cancelled(reason: "The emojis did not match."))
        } catch {
            isBusy = false
            apply(.failed(reason: describe(error)))
        }
    }

    /// Cancel the whole flow. Deliberately not gated on `isBusy` — cancelling has to work
    /// even while another call is in flight, or the sheet can hang.
    func cancel() async {
        do {
            try await controller.cancelVerification()
        } catch {
            // Even on failure, return to idle locally so the UI doesn't hang.
        }
        reset()
    }

    /// Dismiss a terminal state and return to idle.
    func dismiss() {
        reset()
    }

    /// Drop back to the start. Explicit, so unlike `apply(_:)` it is allowed to move the
    /// phase backwards.
    private func reset() {
        phase = .idle
        presented = false
        isBusy = false
        lastFlowId = nil
    }

    // MARK: - State machine

    /// Applies a phase reported by the SDK, ignoring anything that would move the flow
    /// backwards. Ordering is preserved by the event stream, but the SDK can still repeat an
    /// event or report a stale one after a terminal result, and the first terminal result is
    /// the one that counts.
    private func apply(_ next: Phase) {
        guard rank(next) >= rank(phase) else { return }
        guard !isTerminal(phase) else { return }
        guard next != phase else { return }
        phase = next
        // The flow moved on, so whatever call we were waiting on is done with.
        isBusy = false
    }

    /// How far through the flow a phase is. Equal ranks are interchangeable; a lower rank
    /// never replaces a higher one.
    private func rank(_ phase: Phase) -> Int {
        switch phase {
        case .idle: return 0
        case .incomingRequest: return 1
        case .acknowledged: return 2
        case .sasStarting: return 3
        case .emojis: return 4
        case .approved: return 5
        case .finished, .cancelled, .failed: return 6
        }
    }

    private func isTerminal(_ phase: Phase) -> Bool {
        switch phase {
        case .finished, .cancelled, .failed: return true
        default: return false
        }
    }

    // MARK: - Delegate plumbing

    /// A delegate callback, reduced to plain values on the SDK's thread so nothing shared or
    /// FFI-backed crosses over to the main actor.
    fileprivate enum Event: Sendable {
        case request(senderId: String, flowId: String, deviceId: String, deviceName: String?)
        case accepted
        case sasStarted
        case data(items: [Emoji])
        case failed
        case cancelled
        case finished
    }

    private func handle(_ event: Event) {
        switch event {
        case .request(let senderId, let flowId, let deviceId, let deviceName):
            // A request we already know about, re-delivered: ignore it rather than
            // restarting a flow that may already be showing emojis.
            guard flowId != lastFlowId else { return }
            // A different flow id supersedes whatever came before, so this one resets the
            // machine instead of going through `apply`.
            lastFlowId = flowId
            phase = .incomingRequest(senderId: senderId, deviceId: deviceId, deviceName: deviceName)
            isBusy = false
            presented = true
        case .accepted:
            // The other device accepted our request. We are the initiator — we do NOT call
            // startSasVerification here. The receiver (other device) will send the SAS start
            // message, and we'll get didStartSasVerification when it arrives.
            apply(.acknowledged)
        case .sasStarted:
            apply(.sasStarting)
        case .data(let items):
            apply(.emojis(items: items))
        case .failed:
            apply(.failed(reason: nil))
        case .cancelled:
            apply(.cancelled(reason: nil))
        case .finished:
            apply(.finished)
        }
    }

    // MARK: - Sendable callback box

    /// Receives the SDK's callbacks on its own threads and forwards them, in order, as plain
    /// values. `AsyncStream.Continuation` is safe to yield to from any thread.
    final class Box: SessionVerificationControllerDelegate, @unchecked Sendable {
        private let continuation: AsyncStream<Event>.Continuation

        fileprivate init(continuation: AsyncStream<Event>.Continuation) {
            self.continuation = continuation
        }

        deinit {
            // Lets the consumer's `for await` finish once the SDK lets go of us.
            continuation.finish()
        }

        func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
            continuation.yield(.request(
                senderId: details.senderProfile.userId,
                flowId: details.flowId,
                deviceId: details.deviceId,
                deviceName: details.deviceDisplayName
            ))
        }
        func didAcceptVerificationRequest() {
            continuation.yield(.accepted)
        }
        func didStartSasVerification() {
            continuation.yield(.sasStarted)
        }
        func didReceiveVerificationData(data: SessionVerificationData) {
            switch data {
            case .emojis(let raw, _):
                continuation.yield(.data(items: raw.map { Emoji(symbol: $0.symbol(), description: $0.description()) }))
            case .decimals(let values):
                continuation.yield(.data(items: values.map { Emoji(symbol: "\($0)", description: "Code") }))
            }
        }
        func didFail() {
            continuation.yield(.failed)
        }
        func didCancel() {
            continuation.yield(.cancelled)
        }
        func didFinish() {
            continuation.yield(.finished)
        }
    }
}
