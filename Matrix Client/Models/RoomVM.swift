import Foundation
import Combine
import MatrixRustSDK

/// Observable wrapper around a single SDK `Room`. Lazily attaches a Timeline listener +
/// RoomInfo/typing listeners when the room is first opened.
@MainActor
final class RoomVM: ObservableObject, Identifiable {
    let id: String
    private(set) var room: Room
    private weak var session: MatrixSession?

    // From RoomInfo
    @Published var displayName: String = ""
    @Published var topic: String?
    @Published var avatarUrl: String?
    @Published var isDirect: Bool = false
    @Published var isEncrypted: Bool = false
    @Published var membership: Membership = .joined
    @Published var pinnedEventIds: [String] = []
    @Published var joinedMembersCount: UInt64 = 0
    @Published var canonicalAlias: String?
    @Published var unreadNotifications: UInt64 = 0
    @Published var unreadHighlights: UInt64 = 0

    // Live state
    @Published var items: [TimelineItem] = []
    @Published var paginating: Bool = false
    @Published var canPaginate: Bool = true
    @Published var typingUserIds: Set<String> = []
    @Published var members: [String: RoomMember] = [:]
    @Published var membersLoaded: Bool = false

    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var roomInfoHandle: TaskHandle?
    private var typingHandle: TaskHandle?
    private var listenerBox: AnyObject?
    private var autoPaginateTask: Task<Void, Never>?

    init(room: Room, session: MatrixSession) {
        self.id = room.id()
        self.room = room
        self.session = session
        applySnapshotFromRoom()
    }

    /// Update the SDK Room reference (the room list service may hand us a fresh instance
    /// when the underlying state changes — same room id, new handle).
    func update(room: Room) {
        self.room = room
        applySnapshotFromRoom()
    }

    private func applySnapshotFromRoom() {
        displayName = room.displayName() ?? id
        topic = room.topic()
        avatarUrl = room.avatarUrl()
        canonicalAlias = room.canonicalAlias()
        joinedMembersCount = room.joinedMembersCount()
        membership = room.membership()
    }

    func detach() {
        autoPaginateTask?.cancel()
        autoPaginateTask = nil
        timelineHandle = nil
        roomInfoHandle = nil
        typingHandle = nil
        listenerBox = nil
        timeline = nil
    }

    // MARK: - Attach listeners

    /// Open a live timeline + room-info + typing listeners. Idempotent — calling twice is a no-op.
    func openTimeline() async {
        guard timeline == nil else { return }
        do {
            let t = try await room.timeline()
            self.timeline = t
            let listener = TimelineListenerBox { [weak self] diffs in
                Task { @MainActor in self?.applyDiffs(diffs) }
            }
            self.listenerBox = listener
            let handle = await t.addListener(listener: listener)
            self.timelineHandle = handle
        } catch {
            session?.lastError = "Open timeline: \(describe(error))"
        }
        // Room info updates
        let infoListener = RoomInfoBox { [weak self] info in
            Task { @MainActor in self?.apply(info: info) }
        }
        self.roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: infoListener)
        // Typing
        let typingListener = TypingBox { [weak self] ids in
            Task { @MainActor in
                guard let self else { return }
                let me = self.session?.currentUserId
                self.typingUserIds = Set(ids).subtracting(me.map { Set([$0]) } ?? [])
            }
        }
        self.typingHandle = room.subscribeToTypingNotifications(listener: typingListener)

        // Begin loading the full room history in the background.
        startAutoPaginate()
    }

    /// Walk backwards through the timeline until the SDK reports no more history. Runs
    /// in the background so the UI stays interactive. Idempotent — already-running task
    /// is reused.
    func startAutoPaginate() {
        if let t = autoPaginateTask, !t.isCancelled { return }
        guard timeline != nil, canPaginate else { return }
        autoPaginateTask = Task { [weak self] in
            while let self, await !Task.isCancelled {
                let shouldContinue = await MainActor.run { self.canPaginate && self.timeline != nil }
                if !shouldContinue { break }
                await MainActor.run { self.paginating = true }
                let more: Bool
                do {
                    guard let t = await self.timelineHandleSafe else { break }
                    more = try await t.paginateBackwards(numEvents: 100)
                } catch {
                    await MainActor.run {
                        self.session?.lastError = describe(error)
                        self.paginating = false
                    }
                    break
                }
                await MainActor.run {
                    self.canPaginate = more
                    self.paginating = false
                }
                if !more { break }
                // Yield briefly so we don't hog the network or the main thread.
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await MainActor.run { self?.paginating = false }
        }
    }

    /// Background-safe accessor for the timeline handle.
    private var timelineHandleSafe: Timeline? { timeline }

    private func apply(info: RoomInfo) {
        displayName = info.displayName ?? id
        topic = info.topic
        avatarUrl = info.avatarUrl
        isDirect = info.isDirect
        membership = info.membership
        pinnedEventIds = info.pinnedEventIds
        canonicalAlias = info.canonicalAlias
        // EncryptionState is an enum — value `.encrypted` (or similar) indicates E2EE.
        switch info.encryptionState {
        case .encrypted: isEncrypted = true
        default:         isEncrypted = false
        }
    }

    private func applyDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .append(let values):
                items.append(contentsOf: values)
            case .clear:
                items.removeAll()
            case .pushFront(let value):
                items.insert(value, at: 0)
            case .pushBack(let value):
                items.append(value)
            case .popFront:
                if !items.isEmpty { items.removeFirst() }
            case .popBack:
                if !items.isEmpty { items.removeLast() }
            case .insert(let index, let value):
                let i = min(Int(index), items.count)
                items.insert(value, at: i)
            case .set(let index, let value):
                let i = Int(index)
                if i < items.count { items[i] = value } else { items.append(value) }
            case .remove(let index):
                let i = Int(index)
                if i < items.count { items.remove(at: i) }
            case .truncate(let length):
                if items.count > Int(length) {
                    items.removeLast(items.count - Int(length))
                }
            case .reset(let values):
                items = values
            }
        }
    }

    // MARK: - Timeline actions

    func send(_ text: String) async {
        guard let timeline else { return }
        // The SDK converts the markdown body to HTML and populates formatted_body, so other
        // clients render the formatting correctly.
        let msg = messageEventContentFromMarkdown(md: text)
        do {
            _ = try await timeline.send(msg: msg)
        } catch { session?.lastError = describe(error) }
    }

    func sendReply(to eventId: String, text: String) async {
        guard let timeline else { return }
        let msg = messageEventContentFromMarkdown(md: text)
        do {
            try await timeline.sendReply(msg: msg, eventId: eventId)
        } catch { session?.lastError = describe(error) }
    }

    func toggleReaction(targetEventId: String, key: String) async {
        guard let timeline else { return }
        do {
            _ = try await timeline.toggleReaction(itemId: .eventId(eventId: targetEventId), key: key)
        } catch { session?.lastError = describe(error) }
    }

    func redact(eventId: String) async {
        guard let timeline else { return }
        do {
            try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: eventId), reason: nil)
        } catch { session?.lastError = describe(error) }
    }

    func pin(eventId: String) async {
        guard let timeline else { return }
        do { _ = try await timeline.pinEvent(eventId: eventId) }
        catch { session?.lastError = describe(error) }
    }

    func unpin(eventId: String) async {
        guard let timeline else { return }
        do { _ = try await timeline.unpinEvent(eventId: eventId) }
        catch { session?.lastError = describe(error) }
    }

    func togglePin(eventId: String) async {
        if pinnedEventIds.contains(eventId) { await unpin(eventId: eventId) }
        else { await pin(eventId: eventId) }
    }

    func paginate() async {
        guard let timeline, !paginating, canPaginate else { return }
        paginating = true
        defer { paginating = false }
        do {
            let more = try await timeline.paginateBackwards(numEvents: 50)
            canPaginate = more
        } catch { session?.lastError = describe(error) }
    }

    func setTyping(_ typing: Bool) async {
        do { try await room.typingNotice(isTyping: typing) }
        catch { /* swallow */ }
    }

    func markAsRead() async {
        do { try await room.markAsRead(receiptType: .read) }
        catch { /* swallow */ }
    }

    // MARK: - Members + admin

    func loadMembers() async {
        guard !membersLoaded else { return }
        do {
            let iter = try await room.members()
            var collected: [String: RoomMember] = [:]
            while let chunk = iter.nextChunk(chunkSize: 200) {
                for m in chunk { collected[m.userId] = m }
                if chunk.isEmpty { break }
            }
            self.members = collected
            self.membersLoaded = true
        } catch { session?.lastError = describe(error) }
    }

    var myPowerLevel: Int {
        guard let me = session?.currentUserId, let pl = members[me]?.powerLevel else { return 0 }
        switch pl {
        case .infinite: return 10_000
        case .value(let v): return Int(v)
        }
    }

    func powerLevel(of userId: String) -> Int {
        guard let pl = members[userId]?.powerLevel else { return 0 }
        switch pl {
        case .infinite: return 10_000
        case .value(let v): return Int(v)
        }
    }

    func setName(_ name: String) async {
        do { try await room.setName(name: name) }
        catch { session?.lastError = describe(error) }
    }

    func setTopic(_ topic: String) async {
        do { try await room.setTopic(topic: topic) }
        catch { session?.lastError = describe(error) }
    }

    func invite(_ userId: String) async {
        do { try await room.inviteUserById(userId: userId) }
        catch { session?.lastError = describe(error) }
    }

    func kick(_ userId: String, reason: String? = nil) async {
        do { try await room.kickUser(userId: userId, reason: reason) }
        catch { session?.lastError = describe(error) }
    }

    func ban(_ userId: String, reason: String? = nil) async {
        do { try await room.banUser(userId: userId, reason: reason) }
        catch { session?.lastError = describe(error) }
    }

    func unban(_ userId: String) async {
        do { try await room.unbanUser(userId: userId, reason: nil) }
        catch { session?.lastError = describe(error) }
    }

    func setPower(_ userId: String, level: Int) async {
        do {
            try await room.updatePowerLevelsForUsers(updates: [
                UserPowerLevelUpdate(userId: userId, powerLevel: Int64(level))
            ])
        } catch { session?.lastError = describe(error) }
    }

    func leave() async {
        do { try await room.leave() } catch { session?.lastError = describe(error) }
    }

    // MARK: - Convenience

    var heroName: String {
        if !displayName.isEmpty && displayName != id { return displayName }
        return id
    }
}

// MARK: - Listener boxes

final class TimelineListenerBox: TimelineListener, @unchecked Sendable {
    let cb: @Sendable ([TimelineDiff]) -> Void
    init(_ cb: @escaping @Sendable ([TimelineDiff]) -> Void) { self.cb = cb }
    func onUpdate(diff: [TimelineDiff]) { cb(diff) }
}

final class RoomInfoBox: RoomInfoListener, @unchecked Sendable {
    let cb: @Sendable (RoomInfo) -> Void
    init(_ cb: @escaping @Sendable (RoomInfo) -> Void) { self.cb = cb }
    func call(roomInfo: RoomInfo) { cb(roomInfo) }
}

final class TypingBox: TypingNotificationsListener, @unchecked Sendable {
    let cb: @Sendable ([String]) -> Void
    init(_ cb: @escaping @Sendable ([String]) -> Void) { self.cb = cb }
    func call(typingUserIds: [String]) { cb(typingUserIds) }
}
