import Foundation
import Combine
import MatrixRustSDK
import UniformTypeIdentifiers
import ImageIO

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
    private var sdkItems: [TimelineItem] = []
    private var historicalItems: [TimelineItem] = []
    @Published var paginating: Bool = false
    @Published var canPaginate: Bool = true
    // False until the initial timeline burst has loaded + settled, so the UI
    // can show a spinner and only reveal the chat once it will render anchored
    // at the bottom (rather than flashing in mid-load at the wrong position).
    @Published var initialLoadComplete: Bool = false
    @Published var typingUserIds: Set<String> = []
    @Published var members: [String: RoomMember] = [:]
    @Published var membersLoaded: Bool = false

    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var roomInfoHandle: TaskHandle?
    private var typingHandle: TaskHandle?
    private var listenerBox: AnyObject?
    private var autoPaginateTask: Task<Void, Never>?

    // Periodic safety-net refresh. The live timeline under sliding sync doesn't
    // always push reaction / edit / redaction updates to an already-open
    // timeline, so every 3 s we build a throwaway live timeline, hash its
    // content, and only re-attach (surfacing the change) when the hash differs.
    // When nothing changed we touch nothing — no flicker, no scroll jump.
    private var autoRefreshTask: Task<Void, Never>?
    private var lastRefreshSignature: Int = 0
    private var hasRefreshBaseline: Bool = false
    // Once a backward sweep hits the start of history we stop re-sweeping on
    // every refresh-driven reset (the disk cache already has it).
    private var historyFullyLoaded: Bool = false

    /// How many of the most-recent messages a room keeps resident in RAM.
    /// Older history is paginated from the SDK on demand as the user scrolls up.
    private let residentLimit = 100

    // Persisted message cache — loaded from disk on open, updated after each diff burst.
    @Published var cachedMessages: [CachedMessage] = []
    private var saveCacheDebounce: Task<Void, Never>?

    // Long-lived pinned-events timeline. We mirror its event IDs into
    // `pinnedEventIds` so the inline pin indicator updates immediately, even
    // when RoomInfo's pinnedEventIds list is slow to refresh after a pin.
    private var pinnedIndexTimeline: Timeline?
    private var pinnedIndexHandle: TaskHandle?
    private var pinnedIndexBox: AnyObject?
    private var pinnedFromIndex: Set<String> = []
    private var pinnedFromRoomInfo: Set<String> = []

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

    /// Tear everything down and release the room's resident message data so a
    /// closed room stops costing RAM. The disk cache keeps the full history.
    func detach() {
        autoPaginateTask?.cancel()
        autoPaginateTask = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        saveCacheDebounce?.cancel()
        saveCacheDebounce = nil
        timelineHandle = nil
        roomInfoHandle = nil
        typingHandle = nil
        listenerBox = nil
        timeline = nil
        pinnedIndexHandle = nil
        pinnedIndexBox = nil
        pinnedIndexTimeline = nil
        items = []
        sdkItems = []
        historicalItems = []
        cachedMessages = []
        members = [:]
        membersLoaded = false
        typingUserIds = []
        paginating = false
        canPaginate = true
        initialLoadComplete = false
        hasRefreshBaseline = false
        lastRefreshSignature = 0
        historyFullyLoaded = false
    }

    /// Force a complete reload of the timeline (useful if history seems out of sync or stuck).
    /// `detach()` already resets all timeline state, so this is just a teardown + reopen.
    func forceReload() async {
        detach()
        await openTimeline()
    }

    // MARK: - Attach listeners

    /// Subscribe to room metadata (name, avatar, encryption state, pins). Cheap —
    /// no timeline or event data — so every room can stay current in the sidebar
    /// without opening a full timeline. Idempotent.
    func subscribeRoomInfo() {
        guard roomInfoHandle == nil else { return }
        let infoListener = RoomInfoBox { [weak self] info in
            Task { @MainActor in self?.apply(info: info) }
        }
        roomInfoHandle = room.subscribeToRoomInfoUpdates(listener: infoListener)
    }

    /// Open a live timeline + typing listener and load the recent message window.
    /// Idempotent — calling twice is a no-op.
    func openTimeline() async {
        subscribeRoomInfo()
        guard timeline == nil else { return }
        initialLoadComplete = false
        print("[Timeline:\(id.prefix(8))] openTimeline room=\(displayName.prefix(20))")
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
        // Typing
        let typingListener = TypingBox { [weak self] ids in
            Task { @MainActor in
                guard let self else { return }
                let me = self.session?.currentUserId
                self.typingUserIds = Set(ids).subtracting(me.map { Set([$0]) } ?? [])
            }
        }
        self.typingHandle = room.subscribeToTypingNotifications(listener: typingListener)

        // Pre-populate the timeline from disk so history is visible before pagination finishes.
        loadCache()

        // Load just the recent message window into RAM (~residentLimit messages).
        // Older history is paginated on demand as the user scrolls up.
        startAutoPaginate()

        // Open a long-lived pinned-events timeline so we have an authoritative
        // index of pinned event IDs, in addition to whatever RoomInfo reports.
        Task { await openPinnedIndex() }

        // Flip `initialLoadComplete` once the first burst settles so the UI
        // can reveal the chat already anchored at the bottom.
        Task { [weak self] in await self?.markInitialLoadWhenSettled() }
    }

    /// Hold the loading spinner until the recent window (~50 messages) has
    /// actually loaded — or the whole (smaller) room has, or a safety cap is
    /// hit — so the chat reveals already anchored at the bottom.
    private func markInitialLoadWhenSettled() async {
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if items.count >= 50 { break }                 // recent window is in
            if historyFullyLoaded { break }                // whole room loaded
            if !canPaginate && !items.isEmpty { break }    // nothing more to load
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        initialLoadComplete = true
    }

    private func openPinnedIndex() async {
        guard pinnedIndexTimeline == nil else { return }
        let config = TimelineConfiguration(
            focus: .pinnedEvents,
            filter: .all,
            internalIdPrefix: "pinned-index-\(id)",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        do {
            let t = try await room.timelineWithConfiguration(configuration: config)
            self.pinnedIndexTimeline = t
            let listener = TimelineListenerBox { [weak self] diffs in
                Task { @MainActor in self?.applyPinnedIndex(diffs) }
            }
            self.pinnedIndexBox = listener
            self.pinnedIndexHandle = await t.addListener(listener: listener)
        } catch {
            // Non-fatal; we'll fall back to RoomInfo.pinnedEventIds.
        }
    }

    private func applyPinnedIndex(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .append(let v):     for item in v { addPinned(item) }
            case .pushBack(let v):   addPinned(v)
            case .pushFront(let v):  addPinned(v)
            case .insert(_, let v):  addPinned(v)
            case .set(_, let v):     addPinned(v)
            case .reset(let v):
                pinnedFromIndex = []
                for item in v { addPinned(item) }
            case .clear:
                pinnedFromIndex = []
            case .popFront, .popBack, .remove, .truncate:
                // Best-effort: rebuild from current items.
                rebuildPinnedFromIndex()
            }
        }
        recomputePinnedEventIds()
    }

    private func addPinned(_ item: TimelineItem) {
        guard let event = item.asEvent() else { return }
        if case .eventId(let id) = event.eventOrTransactionId {
            pinnedFromIndex.insert(id)
        }
    }

    private func rebuildPinnedFromIndex() {
        guard let t = pinnedIndexTimeline else { return }
        // The SDK doesn't expose the timeline's current items synchronously; we leave
        // this best-effort. RoomInfo will catch up.
        _ = t
    }

    private func recomputePinnedEventIds() {
        // Sorted so the value is stable across recomputes — the pinned sheet keys
        // its fetch off this list via `.task(id:)` and must not churn on reorder.
        let combined = pinnedFromIndex.union(pinnedFromRoomInfo)
        let sorted = combined.sorted()
        if sorted != pinnedEventIds { pinnedEventIds = sorted }
    }

    /// Load the most-recent messages into RAM until the resident window is full
    /// (`residentLimit`) or the start of history is reached. Runs in the background
    /// so the UI stays interactive. Idempotent — an already-running task is reused.
    func startAutoPaginate() {
        guard autoPaginateTask == nil, timeline != nil, canPaginate,
              items.count < residentLimit else { return }
        autoPaginateTask = Task { [weak self] in
            while let self, await !Task.isCancelled {
                let proceed = await MainActor.run {
                    self.canPaginate && self.timeline != nil && self.items.count < self.residentLimit
                }
                if !proceed { break }
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
                    if !more { self.historyFullyLoaded = true }
                }
                if !more { break }
                // Yield briefly so we don't hog the network or the main thread.
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await MainActor.run {
                self?.paginating = false
                self?.autoPaginateTask = nil
            }
        }
    }

    /// Background-safe accessor for the timeline handle.
    private var timelineHandleSafe: Timeline? { timeline }

    // MARK: - Periodic safety-net refresh

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while let self, await !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await self.refreshTick()
            }
        }
    }

    /// Stop the safety-net poll. Called when the room is no longer on screen so
    /// only the visible room runs the 3 s refresh.
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Build a throwaway live timeline, hash its visible content, and only
    /// re-attach the real listener when the hash changed. No change ⇒ we touch
    /// nothing, so the UI (and scroll position) is left exactly as-is.
    private func refreshTick() async {
        // Only poll once the room has settled on screen. Adopting a fresh
        // timeline mid-load would reset pagination progress and thrash the
        // load; until then the live listener already surfaces new messages.
        guard initialLoadComplete,
              timeline != nil, !paginating else { return }
        let config = TimelineConfiguration(
            focus: .live(hideThreadedEvents: false),
            filter: .all,
            internalIdPrefix: "refresh-\(id)",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        guard let fresh = try? await room.timelineWithConfiguration(configuration: config) else { return }
        let acc = DiffAccumulator()
        let tmpBox = TimelineListenerBox { diffs in
            Task { @MainActor in acc.apply(diffs) }
        }
        let tmpHandle = await fresh.addListener(listener: tmpBox)

        // Let the initial burst settle (a few short waits, bail early once stable).
        var lastCount = -1
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let c = acc.items.count
            if c == lastCount && c > 0 { break }
            lastCount = c
        }

        let signature = timelineSignature(acc.items)
        _ = tmpHandle  // keep the temp subscription alive until here
        // First poll just records a baseline — don't adopt (nothing has
        // "changed" yet relative to what's already on screen).
        guard hasRefreshBaseline else {
            hasRefreshBaseline = true
            lastRefreshSignature = signature
            return
        }
        guard signature != lastRefreshSignature else { return }   // nothing changed
        lastRefreshSignature = signature

        // Something changed — adopt this fresh timeline. Attaching the real
        // listener triggers a `.reset` that repopulates sdkItems with correct
        // indices, so future diffs stay consistent.
        guard !Task.isCancelled else { return }
        timelineHandle = nil
        listenerBox = nil
        timeline = fresh
        let liveBox = TimelineListenerBox { [weak self] diffs in
            Task { @MainActor in self?.applyDiffs(diffs) }
        }
        listenerBox = liveBox
        timelineHandle = await fresh.addListener(listener: liveBox)
    }

    private func timelineSignature(_ items: [TimelineItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            guard let ev = item.asEvent() else {
                hasher.combine(item.uniqueId().id)
                continue
            }
            if case .eventId(let eid) = ev.eventOrTransactionId {
                hasher.combine(eid)
            } else {
                hasher.combine(item.uniqueId().id)
            }
            hasher.combine(Int(ev.timestamp))
            if case .msgLike(let content) = ev.content {
                switch content.kind {
                case .message(let m):
                    hasher.combine(m.body)
                    hasher.combine(m.isEdited)
                case .redacted:
                    hasher.combine("redacted")
                default:
                    break
                }
                for r in content.reactions.sorted(by: { $0.key < $1.key }) {
                    hasher.combine(r.key)
                    hasher.combine(r.senders.count)
                }
            }
        }
        return hasher.finalize()
    }

    private func apply(info: RoomInfo) {
        displayName = info.displayName ?? id
        topic = info.topic
        avatarUrl = info.avatarUrl
        isDirect = info.isDirect
        membership = info.membership
        pinnedFromRoomInfo = Set(info.pinnedEventIds)
        recomputePinnedEventIds()
        canonicalAlias = info.canonicalAlias
        // EncryptionState is an enum — value `.encrypted` (or similar) indicates E2EE.
        switch info.encryptionState {
        case .encrypted: isEncrypted = true
        default:         isEncrypted = false
        }
    }

    private func applyDiffs(_ diffs: [TimelineDiff]) {
        let tag = "[Diff:\(id.prefix(8))]"
        for diff in diffs {
            switch diff {
            case .append(let values):
                sdkItems.append(contentsOf: values)
            case .clear:
                print("\(tag) .clear (sdk=\(sdkItems.count) hist=\(historicalItems.count))")
                for item in items {
                    if !historicalItems.contains(where: { $0.uniqueId().id == item.uniqueId().id }) {
                        historicalItems.append(item)
                    }
                }
                sdkItems.removeAll()
                canPaginate = !historyFullyLoaded
                autoPaginateTask?.cancel()
                autoPaginateTask = nil
                if !historyFullyLoaded { startAutoPaginate() }
            case .pushFront(let value):
                sdkItems.insert(value, at: 0)
            case .pushBack(let value):
                sdkItems.append(value)
            case .popFront:
                if !sdkItems.isEmpty { sdkItems.removeFirst() }
            case .popBack:
                if !sdkItems.isEmpty { sdkItems.removeLast() }
            case .insert(let index, let value):
                let i = min(Int(index), sdkItems.count)
                sdkItems.insert(value, at: i)
            case .set(let index, let value):
                let i = Int(index)
                if i < sdkItems.count { sdkItems[i] = value } else { sdkItems.append(value) }
            case .remove(let index):
                let i = Int(index)
                if i < sdkItems.count { sdkItems.remove(at: i) }
            case .truncate(let length):
                print("\(tag) .truncate(\(length)) sdk was \(sdkItems.count)")
                if sdkItems.count > Int(length) {
                    sdkItems.removeLast(sdkItems.count - Int(length))
                }
            case .reset(let values):
                print("\(tag) .reset to \(values.count) items (was sdk=\(sdkItems.count) hist=\(historicalItems.count))")
                for item in sdkItems {
                    if !historicalItems.contains(where: { $0.uniqueId().id == item.uniqueId().id }) {
                        historicalItems.append(item)
                    }
                }
                sdkItems = values
                canPaginate = !historyFullyLoaded
                autoPaginateTask?.cancel()
                autoPaginateTask = nil
                if !historyFullyLoaded { startAutoPaginate() }
            }
        }
        
        // Rebuild public `items` to include both historical + live items without duplicates
        var newItems = historicalItems
        newItems.removeAll { histItem in
            sdkItems.contains(where: { $0.uniqueId().id == histItem.uniqueId().id })
        }
        newItems.append(contentsOf: sdkItems)
        items = dedupedForDisplay(newItems)

        scheduleCacheSave()
    }

    /// Collapse items that resolve to the same SwiftUI `ForEach` identity
    /// (event id, or unique id for virtuals). After a refresh adoption or the
    /// history bridge merge, the same event can appear twice — a stale
    /// historical copy and a fresh one with a different SDK `uniqueId`. Keep
    /// the LAST occurrence: the freshest copy sits later in the list.
    private func dedupedForDisplay(_ list: [TimelineItem]) -> [TimelineItem] {
        var seen = Set<String>()
        var reversed: [TimelineItem] = []
        reversed.reserveCapacity(list.count)
        for item in list.reversed() {
            let key: String
            if let ev = item.asEvent(), case .eventId(let eid) = ev.eventOrTransactionId {
                key = "e:" + eid
            } else {
                key = "u:" + item.uniqueId().id
            }
            if seen.insert(key).inserted {
                reversed.append(item)
            }
        }
        return reversed.reversed()
    }

    // MARK: - Timeline actions

    func send(_ text: String, mentions: [MentionRef] = []) async {
        guard let timeline else { return }
        let msg = buildOutgoingMessage(text: text, mentions: mentions)
        do {
            _ = try await timeline.send(msg: msg)
        } catch {
            session?.lastError = describe(error)
        }
    }

    func sendReply(to eventId: String, text: String, mentions: [MentionRef] = []) async {
        guard let timeline else { return }
        let msg = buildOutgoingMessage(text: text, mentions: mentions)
        do {
            try await timeline.sendReply(msg: msg, eventId: eventId)
        } catch { session?.lastError = describe(error) }
    }

    func sendEdit(to eventId: String, text: String, mentions: [MentionRef] = []) async {
        guard let timeline else { return }
        let msg = buildOutgoingMessage(text: text, mentions: mentions)
        do {
            try await timeline.edit(eventOrTransactionId: .eventId(eventId: eventId), newContent: .roomMessage(content: msg))
        } catch { session?.lastError = describe(error) }
    }

    /// Turn composer text into send-ready content: slash commands / spoilers first,
    /// then mention pills (so a mentioned user is actually notified), else plain
    /// markdown that the SDK converts to a `formatted_body` for us.
    private func buildOutgoingMessage(text: String, mentions: [MentionRef]) -> RoomMessageEventContentWithoutRelation {
        switch SlashCommandParser.parse(text) {
        case .rainbow(let body):
            let pair = MessageBuilder.rainbow(body)
            return buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .spoiler(let body):
            let pair = MessageBuilder.spoiler(body)
            return buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .perLineSpoiler(let body):
            let pair = MessageBuilder.perLineSpoilers(body)
            return buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .none:
            if text.contains("||") {
                let pair = MessageBuilder.inlineSpoilers(text)
                return buildHTMLMessage(plain: pair.plain, html: pair.html)
            }
            if let mentionMsg = buildMentionMessage(text: text, mentions: mentions) {
                return mentionMsg
            }
            // Plain markdown — SDK converts to HTML formatted_body automatically.
            return messageEventContentFromMarkdown(md: text)
        }
    }

    private func buildHTMLMessage(plain: String, html: String) -> RoomMessageEventContentWithoutRelation {
        let content = MessageContent(
            msgType: .text(content: TextMessageContent(
                body: plain,
                formatted: FormattedBody(format: .html, body: html)
            )),
            body: plain,
            isEdited: false,
            mentions: nil
        )
        // Fall back to plain text if the SDK conversion throws — should never happen for
        // hand-built content with no relations.
        return (try? contentWithoutRelationFromMessage(message: content))
            ?? messageEventContentFromMarkdown(md: plain)
    }

    /// Build a message that carries real Matrix mentions via `m.mentions.user_ids`
    /// — which is what actually notifies the mentioned user. The mention is sent as
    /// plain `@name` text, with no embedded `matrix.to` link. Returns nil when none
    /// of the tracked mentions still appear in `text` (the caller then falls back to
    /// the plain markdown path).
    private func buildMentionMessage(text: String, mentions: [MentionRef]) -> RoomMessageEventContentWithoutRelation? {
        guard !mentions.isEmpty else { return nil }
        // Longest names first so a short name can't shadow a longer one that
        // starts with it (e.g. "@al" vs "@alice").
        let refs = mentions.filter { !$0.name.isEmpty }
            .sorted { $0.name.count > $1.name.count }

        var matchedIds: [String] = []
        var idx = text.startIndex
        // A mention token only counts at a word boundary (start of text or after
        // whitespace), mirroring the composer's own @-detection.
        var atBoundary = true
        while idx < text.endIndex {
            var matched = false
            if atBoundary {
                for ref in refs {
                    let token = "@\(ref.name)"
                    if text[idx...].hasPrefix(token) {
                        if !matchedIds.contains(ref.userId) { matchedIds.append(ref.userId) }
                        idx = text.index(idx, offsetBy: token.count)
                        matched = true
                        break
                    }
                }
            }
            if matched {
                atBoundary = false
                continue
            }
            let ch = text[idx]
            atBoundary = ch == " " || ch == "\n" || ch == "\t" || ch == "\r"
            idx = text.index(after: idx)
        }
        guard !matchedIds.isEmpty else { return nil }

        // Plain-text body + `m.mentions` only — no formatted HTML, so the mention
        // notifies the user without rendering as a link on any client.
        let content = MessageContent(
            msgType: .text(content: TextMessageContent(body: text, formatted: nil)),
            body: text,
            isEdited: false,
            mentions: Mentions(userIds: matchedIds, room: false)
        )
        return try? contentWithoutRelationFromMessage(message: content)
    }

    /// Send one or more files (images, videos, or generic files) from local URLs.
    func sendAttachments(_ urls: [URL]) async {
        for url in urls {
            await sendAttachment(url)
        }
    }

    /// Send a single file attachment. Reads the file into memory to avoid
    /// security-scoped resource timing issues, then sends via the SDK.
    func sendAttachment(_ url: URL) async {
        NSLog("[upload] sendAttachment: \(url.lastPathComponent) — timeline=\(timeline != nil ? "open" : "NIL")")
        guard let timeline else {
            NSLog("[upload] sendAttachment ABORTED: room \(id.prefix(8)) has no open timeline")
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let mime = mimeType(for: url)

        // Read file data into memory so the security-scoped resource doesn't
        // expire before the SDK's background upload finishes.
        guard let fileData = try? Data(contentsOf: url) else {
            NSLog("[upload] sendAttachment ERROR: cannot read \(url.path) (sandbox? scoped=\(accessing))")
            session?.lastError = "Failed to read file: \(filename)"
            return
        }

        let params = UploadParameters(
            source: .data(bytes: fileData, filename: filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )

        do {
            if mime.hasPrefix("image/") {
                try sendImageData(fileData, filename: filename, mime: mime, timeline: timeline)
            } else if mime.hasPrefix("video/") {
                let info = VideoInfo(
                    duration: nil, height: nil, width: nil,
                    mimetype: mime, size: UInt64(fileData.count),
                    thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil
                )
                _ = try timeline.sendVideo(params: params, thumbnailSource: nil, videoInfo: info)
            } else if mime.hasPrefix("audio/") {
                let info = AudioInfo(duration: nil, size: UInt64(fileData.count), mimetype: mime)
                _ = try timeline.sendAudio(params: params, audioInfo: info)
            } else {
                let info = FileInfo(
                    mimetype: mime, size: UInt64(fileData.count),
                    thumbnailInfo: nil, thumbnailSource: nil
                )
                _ = try timeline.sendFile(params: params, fileInfo: info)
            }
            NSLog("[upload] sendAttachment OK: \(filename) [\(mime)] \(fileData.count) bytes handed to send queue")
        } catch {
            NSLog("[upload] sendAttachment ERROR for \(filename): \(describe(error))")
            session?.lastError = describe(error)
        }
    }

    /// Send raw data (e.g. from clipboard paste or drag-and-drop).
    func sendData(_ data: Data, filename: String, mime: String) async {
        NSLog("[upload] sendData: \(filename) [\(mime)] \(data.count) bytes — timeline=\(timeline != nil ? "open" : "NIL")")
        guard let timeline else {
            NSLog("[upload] sendData ABORTED: room \(id.prefix(8)) has no open timeline")
            return
        }
        let params = UploadParameters(
            source: .data(bytes: data, filename: filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        do {
            if mime.hasPrefix("image/") {
                try sendImageData(data, filename: filename, mime: mime, timeline: timeline)
            } else if mime.hasPrefix("video/") {
                let info = VideoInfo(
                    duration: nil, height: nil, width: nil,
                    mimetype: mime, size: UInt64(data.count),
                    thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil
                )
                _ = try timeline.sendVideo(params: params, thumbnailSource: nil, videoInfo: info)
            } else if mime.hasPrefix("audio/") {
                let info = AudioInfo(duration: nil, size: UInt64(data.count), mimetype: mime)
                _ = try timeline.sendAudio(params: params, audioInfo: info)
            } else {
                let info = FileInfo(
                    mimetype: mime, size: UInt64(data.count),
                    thumbnailInfo: nil, thumbnailSource: nil
                )
                _ = try timeline.sendFile(params: params, fileInfo: info)
            }
            NSLog("[upload] sendData OK: \(filename) handed to send queue")
        } catch {
            NSLog("[upload] sendData ERROR for \(filename): \(describe(error))")
            session?.lastError = describe(error)
        }
    }

    private func mimeType(for url: URL) -> String {
        if let uti = UTType(filenameExtension: url.pathExtension) {
            return uti.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    /// Send image bytes. Transcodes to a format the SDK + other clients
    /// reliably accept (PNG/JPEG/GIF pass through; HEIC/TIFF/BMP/WebP/etc.
    /// become PNG) and attaches a complete `ImageInfo`. If `sendImage` is still
    /// rejected, falls back to a plain file send so the upload always lands.
    private func sendImageData(_ data: Data, filename: String, mime: String, timeline: Timeline) throws {
        NSLog("[upload] sendImageData: \(filename) [\(mime)] \(data.count) bytes in")
        let prepared = prepareImageForSending(data)
        let outData = prepared?.data ?? data
        let outMime = prepared?.mime ?? mime
        let outName = prepared.map { swapExtension(filename, to: $0.ext) } ?? filename
        let params = UploadParameters(
            source: .data(bytes: outData, filename: outName),
            caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: nil
        )
        if let prepared {
            do {
                _ = try timeline.sendImage(params: params, thumbnailSource: nil, imageInfo: prepared.info)
                NSLog("[upload] sendImage OK: \(outName) [\(outMime)] \(outData.count) bytes")
                return
            } catch {
                NSLog("[upload] sendImage REJECTED for \(outName): \(describe(error)) — falling back to a plain file send")
            }
        } else {
            NSLog("[upload] \(filename) did not decode as an image — sending as a plain file")
        }
        let fileInfo = FileInfo(
            mimetype: outMime, size: UInt64(outData.count),
            thumbnailInfo: nil, thumbnailSource: nil
        )
        _ = try timeline.sendFile(params: params, fileInfo: fileInfo)
        NSLog("[upload] sendFile OK (image path): \(outName) [\(outMime)] \(outData.count) bytes")
    }

    /// Decode image bytes with ImageIO and return canonical, broadly-supported
    /// bytes plus a complete `ImageInfo`. PNG/JPEG/GIF are returned unchanged;
    /// anything else (HEIC, TIFF, BMP, WebP, …) is transcoded to PNG. Returns
    /// nil when the bytes aren't a decodable image.
    private func prepareImageForSending(_ data: Data)
        -> (data: Data, mime: String, ext: String, info: ImageInfo)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let utiCF = CGImageSourceGetType(src) else {
            NSLog("[upload] prepareImage: \(data.count) bytes did not decode as an image")
            return nil
        }
        let uti = utiCF as String
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value

        func info(_ mime: String, _ size: Int, animated: Bool?) -> ImageInfo {
            ImageInfo(height: height, width: width, mimetype: mime, size: UInt64(size),
                      thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: animated)
        }

        let type = UTType(uti)
        if type == .png {
            return (data, "image/png", "png", info("image/png", data.count, animated: nil))
        }
        if type == .jpeg {
            return (data, "image/jpeg", "jpg", info("image/jpeg", data.count, animated: nil))
        }
        if type == .gif {
            return (data, "image/gif", "gif", info("image/gif", data.count, animated: true))
        }

        // HEIC / TIFF / BMP / WebP / … → transcode to PNG.
        let out = NSMutableData()
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            NSLog("[upload] prepareImage: could not set up \(uti) → PNG transcode")
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest), out.length > 0 else {
            NSLog("[upload] prepareImage: \(uti) → PNG transcode failed")
            return nil
        }
        let png = out as Data
        NSLog("[upload] prepareImage: transcoded \(uti) → PNG (\(data.count) → \(png.count) bytes)")
        return (png, "image/png", "png", info("image/png", png.count, animated: nil))
    }

    /// Replace a filename's extension (e.g. after transcoding an image to PNG).
    private func swapExtension(_ filename: String, to ext: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return "\(base.isEmpty ? "image" : base).\(ext)"
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

    /// Cancel a still-sending (or send-failed) local echo. Redacting a local
    /// echo by its transaction id removes it from the send queue — the only
    /// way to clear a message wedged in "sending" (e.g. a stuck upload).
    func cancelSend(transactionId: String) async {
        guard let timeline else { return }
        do {
            try await timeline.redactEvent(
                eventOrTransactionId: .transactionId(transactionId: transactionId),
                reason: nil
            )
        } catch { session?.lastError = describe(error) }
    }

    func pin(eventId: String) async {
        guard let timeline else { return }
        // Optimistic: flip the indicator immediately so the UI feels responsive,
        // even before the state event echoes back via sync.
        pinnedFromRoomInfo.insert(eventId)
        recomputePinnedEventIds()
        do { _ = try await timeline.pinEvent(eventId: eventId) }
        catch {
            // Roll back on failure.
            pinnedFromRoomInfo.remove(eventId)
            recomputePinnedEventIds()
            session?.lastError = describe(error)
        }
    }

    func unpin(eventId: String) async {
        guard let timeline else { return }
        pinnedFromRoomInfo.remove(eventId)
        pinnedFromIndex.remove(eventId)
        recomputePinnedEventIds()
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

    // MARK: - Message cache

    struct CachedMessage: Identifiable, Codable {
        let id: String            // event_id
        let sender: String        // MXID
        let senderName: String?   // display name from senderProfile (nil for imported)
        let senderAvatar: String? // MXC URL from senderProfile (nil for imported)
        let timestamp: Int64      // origin_server_ts in milliseconds
        let body: String
        let formattedBody: String?
        let isImported: Bool      // true = from Element JSON export

        var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
    }

    private func loadCache() {
        cachedMessages = CacheStore.load(roomId: id)
    }

    /// Coalesces rapid diff bursts into a single write ~2 s after the last change.
    private func scheduleCacheSave() {
        saveCacheDebounce?.cancel()
        saveCacheDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let (roomId, snapshot) = await MainActor.run { (self.id, self.buildCacheSnapshot()) }
            // Never let an empty snapshot (e.g. from a detached room) clobber the disk cache.
            guard !snapshot.isEmpty else { return }
            CacheStore.save(snapshot, roomId: roomId)
            await MainActor.run { self.cachedMessages = snapshot }
        }
    }

    /// Merges imported entries with messages extracted from the current SDK `items`.
    private func buildCacheSnapshot() -> [CachedMessage] {
        var byId: [String: CachedMessage] = Dictionary(
            uniqueKeysWithValues: cachedMessages.map { ($0.id, $0) }
        )
        for item in items {
            guard let msg = item.toCachedMessage() else { continue }
            byId[msg.id] = msg
        }
        return byId.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Parses one or more Element JSON export files and merges them into the cache.
    /// Only `m.room.message` events are kept.
    func loadImport(from urls: [URL]) {
        var byId: [String: CachedMessage] = Dictionary(
            uniqueKeysWithValues: cachedMessages.map { ($0.id, $0) }
        )
        let decoder = JSONDecoder()
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let events = try? decoder.decode([_ElementExportEvent].self, from: data) else { continue }
            for event in events where event.type == "m.room.message" {
                let msg = CachedMessage(
                    id: event.eventId,
                    sender: event.sender,
                    senderName: nil,
                    senderAvatar: nil,
                    timestamp: event.originServerTs,
                    body: event.content.body ?? "",
                    formattedBody: event.content.formattedBody,
                    isImported: true
                )
                byId[msg.id] = msg
            }
        }
        let sorted = byId.values.sorted { $0.timestamp < $1.timestamp }
        cachedMessages = sorted
        CacheStore.save(sorted, roomId: id)
    }

    func clearImport() {
        cachedMessages = cachedMessages.filter { !$0.isImported }
        CacheStore.save(cachedMessages, roomId: id)
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

// MARK: - CacheStore

private enum CacheStore {
    static func load(roomId: String) -> [RoomVM.CachedMessage] {
        guard let url = url(for: roomId),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RoomVM.CachedMessage].self, from: data)) ?? []
    }

    static func save(_ messages: [RoomVM.CachedMessage], roomId: String) {
        guard let url = url(for: roomId) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func url(for roomId: String) -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let safe = roomId
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: ":", with: "_")
        return support
            .appendingPathComponent("MatrixClient/rooms/\(safe)")
            .appendingPathExtension("json")
    }
}

// MARK: - Element export decode helpers

private struct _ElementExportEvent: Codable {
    let eventId: String
    let sender: String
    let originServerTs: Int64
    let type: String
    let content: _ElementExportContent

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case sender
        case originServerTs = "origin_server_ts"
        case type
        case content
    }
}

private struct _ElementExportContent: Codable {
    let body: String?
    let formattedBody: String?

    private enum CodingKeys: String, CodingKey {
        case body
        case formattedBody = "formatted_body"
    }
}

// MARK: - TimelineItem → CachedMessage

private extension TimelineItem {
    func toCachedMessage() -> RoomVM.CachedMessage? {
        guard let event = asEvent(),
              case .eventId(let eventId) = event.eventOrTransactionId,
              case .msgLike(let content) = event.content,
              case .message(let msg) = content.kind else { return nil }

        let body: String
        let html: String?
        if case .text(let t) = msg.msgType {
            body = t.body
            html = t.formatted?.body
        } else if case .notice(let n) = msg.msgType {
            body = n.body
            html = n.formatted?.body
        } else if case .emote(let e) = msg.msgType {
            body = "* \(e.body)"
            html = nil
        } else {
            body = msg.body
            html = nil
        }

        var senderDisplayName: String? = nil
        var senderAvatarMxc: String? = nil
        if case .ready(let name, _, let avatar) = event.senderProfile {
            senderDisplayName = name
            senderAvatarMxc = avatar
        }

        return RoomVM.CachedMessage(
            id: eventId,
            sender: event.sender,
            senderName: senderDisplayName,
            senderAvatar: senderAvatarMxc,
            timestamp: Int64(event.timestamp),
            body: body,
            formattedBody: html,
            isImported: false
        )
    }
}
