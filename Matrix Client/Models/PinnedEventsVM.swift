import Foundation
import Combine
import MatrixRustSDK

/// Observable backing for the Pinned Messages sheet.
///
/// The `.pinnedEvents` timeline focus does not reliably deliver items under
/// sliding sync (the sheet came up empty). Instead we take the authoritative
/// pinned id list from `RoomInfo` (mirrored into `RoomVM.pinnedEventIds`) and
/// fetch each event with a short-lived `.event`-focused timeline — the same
/// mechanism permalinks/the history bridge use, which fetches the event from
/// the server even when it isn't in the live timeline cache.
@MainActor
final class PinnedEventsVM: ObservableObject {
    @Published private(set) var items: [TimelineItem] = []
    @Published private(set) var loading: Bool = true
    @Published var error: String?

    private let room: Room
    // Focused timelines + listener handles are kept alive while the sheet is
    // open so the SDK keeps the fetched events resident.
    private var timelines: [Timeline] = []
    private var handles: [TaskHandle] = []
    private var boxes: [AnyObject] = []

    init(room: Room) {
        self.room = room
    }

    /// Fetch every pinned event by id. Called with `RoomVM.pinnedEventIds`; the
    /// view re-invokes this whenever that list changes.
    func open(eventIds: [String]) async {
        close()
        loading = true
        defer { loading = false }
        error = nil
        guard !eventIds.isEmpty else { items = []; return }

        var collected: [TimelineItem] = []
        for id in eventIds.prefix(100) {
            if let item = await fetchEvent(id) { collected.append(item) }
        }
        items = collected.sorted { lhs, rhs in
            let l = lhs.asEvent().map { Int64($0.timestamp) } ?? 0
            let r = rhs.asEvent().map { Int64($0.timestamp) } ?? 0
            return l < r
        }
        // Only flag an error when the server says there ARE pinned events but
        // every individual fetch timed out — not when the pin list is simply empty.
        if items.isEmpty {
            error = "Pinned events exist but couldn't be loaded — they may be too old for the server cache. Try scrolling back to them in the timeline first."
        }
    }

    private func fetchEvent(_ id: String) async -> TimelineItem? {
        let config = TimelineConfiguration(
            focus: .event(eventId: id, numContextEvents: 1,
                           threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all,
            internalIdPrefix: "pin-\(id)",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        guard let t = try? await room.timelineWithConfiguration(configuration: config) else {
            return nil
        }
        let acc = DiffAccumulator()
        // Lock-guarded accumulator — no need to bounce off the SDK's thread.
        let listener = PinnedListenerBox { diffs in acc.apply(diffs) }
        let handle = await t.addListener(listener: listener)
        timelines.append(t)
        handles.append(handle)
        boxes.append(listener)

        // Wait (up to ~8s) for the focal event to arrive. Pinned events are
        // often old messages that aren't in the local cache, so the SDK may
        // need a server round-trip to fetch them before the listener fires.
        for _ in 0..<40 {
            if acc.items.contains(where: { Self.matches($0, id) }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return acc.items.first(where: { Self.matches($0, id) })
    }

    private static func matches(_ item: TimelineItem, _ id: String) -> Bool {
        guard let ev = item.asEvent() else { return false }
        if case .eventId(let e) = ev.eventOrTransactionId { return e == id }
        return false
    }

    func close() {
        handles = []
        boxes = []
        timelines = []
        items = []
    }
}

/// Tiny lock-guarded accumulator that replays timeline diffs into a flat array.
/// Deliberately *not* `@MainActor`: the SDK delivers timeline-listener
/// callbacks on its own thread, and forcing each burst back onto the main
/// actor just to mutate a local helper used to cost a main-thread hop per
/// callback (visible as scroll jank during heavy traffic). The lock keeps
/// reads and writes consistent across whatever threads end up touching it.
final class DiffAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [TimelineItem] = []

    var items: [TimelineItem] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func apply(_ diffs: [TimelineDiff]) {
        lock.lock(); defer { lock.unlock() }
        for diff in diffs {
            switch diff {
            case .append(let v):     _items.append(contentsOf: v)
            case .clear:             _items.removeAll()
            case .pushFront(let v):  _items.insert(v, at: 0)
            case .pushBack(let v):   _items.append(v)
            case .popFront:          if !_items.isEmpty { _items.removeFirst() }
            case .popBack:           if !_items.isEmpty { _items.removeLast() }
            case .insert(let i, let v):
                _items.insert(v, at: min(Int(i), _items.count))
            case .set(let i, let v):
                let idx = Int(i)
                if idx < _items.count { _items[idx] = v } else { _items.append(v) }
            case .remove(let i):
                let idx = Int(i)
                if idx < _items.count { _items.remove(at: idx) }
            case .truncate(let len):
                if _items.count > Int(len) { _items.removeLast(_items.count - Int(len)) }
            case .reset(let v):
                _items = v
            }
        }
    }
}

final class PinnedListenerBox: TimelineListener, @unchecked Sendable {
    let cb: @Sendable ([TimelineDiff]) -> Void
    init(_ cb: @escaping @Sendable ([TimelineDiff]) -> Void) { self.cb = cb }
    func onUpdate(diff: [TimelineDiff]) { cb(diff) }
}
