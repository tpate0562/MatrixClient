import Foundation
import Combine
import MatrixRustSDK

/// Observable backing for the Pinned Messages sheet. Opens a Timeline focused on the
/// room's pinned events — the SDK fetches the underlying events even if they aren't in
/// the live timeline cache yet.
@MainActor
final class PinnedEventsVM: ObservableObject {
    @Published private(set) var items: [TimelineItem] = []
    @Published private(set) var loading: Bool = true
    @Published var error: String?

    private let room: Room
    private var timeline: Timeline?
    private var handle: TaskHandle?
    private var listenerBox: AnyObject?

    init(room: Room) {
        self.room = room
    }

    func open() async {
        guard timeline == nil else { return }
        loading = true
        defer { loading = false }
        let config = TimelineConfiguration(
            focus: .pinnedEvents,
            filter: .all,
            internalIdPrefix: "pinned-\(room.id())",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        do {
            let t = try await room.timelineWithConfiguration(configuration: config)
            self.timeline = t
            let listener = PinnedListenerBox { [weak self] diffs in
                Task { @MainActor in self?.apply(diffs) }
            }
            self.listenerBox = listener
            self.handle = await t.addListener(listener: listener)
        } catch {
            self.error = describe(error)
        }
    }

    func close() {
        handle = nil
        listenerBox = nil
        timeline = nil
        items = []
    }

    private func apply(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .append(let v):     items.append(contentsOf: v)
            case .clear:             items.removeAll()
            case .pushFront(let v):  items.insert(v, at: 0)
            case .pushBack(let v):   items.append(v)
            case .popFront:          if !items.isEmpty { items.removeFirst() }
            case .popBack:           if !items.isEmpty { items.removeLast() }
            case .insert(let i, let v):
                let idx = min(Int(i), items.count)
                items.insert(v, at: idx)
            case .set(let i, let v):
                let idx = Int(i)
                if idx < items.count { items[idx] = v } else { items.append(v) }
            case .remove(let i):
                let idx = Int(i)
                if idx < items.count { items.remove(at: idx) }
            case .truncate(let len):
                if items.count > Int(len) { items.removeLast(items.count - Int(len)) }
            case .reset(let v):
                items = v
            }
        }
    }
}

final class PinnedListenerBox: TimelineListener, @unchecked Sendable {
    let cb: @Sendable ([TimelineDiff]) -> Void
    init(_ cb: @escaping @Sendable ([TimelineDiff]) -> Void) { self.cb = cb }
    func onUpdate(diff: [TimelineDiff]) { cb(diff) }
}
