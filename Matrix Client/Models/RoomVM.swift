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
    @Published var typingUserIds: Set<String> = []
    @Published var members: [String: RoomMember] = [:]
    @Published var membersLoaded: Bool = false

    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var roomInfoHandle: TaskHandle?
    private var typingHandle: TaskHandle?
    private var listenerBox: AnyObject?
    private var autoPaginateTask: Task<Void, Never>?

    // Bridge timeline: used to continue history past the sliding-sync prev_batch wall
    // by anchoring at the oldest known event and using the /context API token chain.
    private var bridgeTimeline: Timeline?
    private var bridgeHandle: TaskHandle?
    private var bridgeBox: AnyObject?
    private var bridgeItems: [TimelineItem] = []

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

    func detach() {
        autoPaginateTask?.cancel()
        autoPaginateTask = nil
        timelineHandle = nil
        roomInfoHandle = nil
        typingHandle = nil
        listenerBox = nil
        timeline = nil
        bridgeHandle = nil
        bridgeBox = nil
        bridgeTimeline = nil
        bridgeItems = []
        pinnedIndexHandle = nil
        pinnedIndexBox = nil
        pinnedIndexTimeline = nil
    }

    /// Force a complete reload of the timeline (useful if history seems out of sync or stuck).
    func forceReload() async {
        detach()
        items.removeAll()
        historicalItems.removeAll()
        sdkItems.removeAll()
        canPaginate = true
        paginating = false
        await openTimeline()
    }

    // MARK: - Attach listeners

    /// Open a live timeline + room-info + typing listeners. Idempotent — calling twice is a no-op.
    func openTimeline() async {
        guard timeline == nil else { return }
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

        // Open a long-lived pinned-events timeline so we have an authoritative
        // index of pinned event IDs, in addition to whatever RoomInfo reports.
        Task { await openPinnedIndex() }
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
        let combined = pinnedFromIndex.union(pinnedFromRoomInfo)
        pinnedEventIds = Array(combined)
    }

    /// Walk backwards through the timeline until the SDK reports no more history. Runs
    /// in the background so the UI stays interactive. Idempotent — already-running task
    /// is reused.
    func startAutoPaginate() {
        guard autoPaginateTask == nil else {
            print("[Pagination:\(id.prefix(8))] startAutoPaginate – skipped, task already running")
            return
        }
        guard timeline != nil else {
            print("[Pagination:\(id.prefix(8))] startAutoPaginate – skipped, no timeline")
            return
        }
        guard canPaginate else {
            print("[Pagination:\(id.prefix(8))] startAutoPaginate – skipped, canPaginate=false")
            return
        }
        print("[Pagination:\(id.prefix(8))] startAutoPaginate – starting (items=\(items.count))")
        let roomId = String(id.prefix(8))
        autoPaginateTask = Task { [weak self] in
            var page = 0
            while let self, await !Task.isCancelled {
                let shouldContinue = await MainActor.run { self.canPaginate && self.timeline != nil }
                if !shouldContinue { break }
                await MainActor.run { self.paginating = true }
                let more: Bool
                do {
                    guard let t = await self.timelineHandleSafe else {
                        print("[Pagination:\(roomId)] no timeline handle – stopping")
                        break
                    }
                    more = try await t.paginateBackwards(numEvents: 100)
                    page += 1
                    let count = await MainActor.run { self.items.count }
                    print("[Pagination:\(roomId)] page \(page) – more=\(more) items=\(count)")
                } catch {
                    print("[Pagination:\(roomId)] ERROR page \(page): \(error)")
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
                if !more {
                    let count = await MainActor.run { self.items.count }
                    print("[Pagination:\(roomId)] reached sync wall after \(page) pages, \(count) items — trying context bridge")
                    await self.runBridgePagination(roomId: roomId)
                    break
                }
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

    /// Opens a focused timeline anchored at the oldest known event, which uses the
    /// server's /context API for its initial token — a different chain than the
    /// sliding-sync prev_batch. This bridges pagination gaps where the sync wall
    /// stops before the room's true start.
    private func runBridgePagination(roomId: String) async {
        let anchor = await MainActor.run { () -> String? in
            items.compactMap { item -> String? in
                guard let ev = item.asEvent() else { return nil }
                if case .eventId(let eid) = ev.eventOrTransactionId { return eid }
                return nil
            }.first
        }
        guard let anchor else {
            print("[Pagination:\(roomId)] bridge – no anchor event, skipping")
            return
        }
        print("[Pagination:\(roomId)] bridge – anchor=\(anchor.prefix(16))")
        let config = TimelineConfiguration(
            focus: .event(eventId: anchor, numContextEvents: 20,
                          threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all,
            internalIdPrefix: "bridge-\(id.prefix(8))",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false
        )
        do {
            let t = try await room.timelineWithConfiguration(configuration: config)
            await MainActor.run { self.bridgeTimeline = t }
            let listener = TimelineListenerBox { [weak self] diffs in
                Task { @MainActor in self?.applyBridgeDiffs(diffs) }
            }
            await MainActor.run { self.bridgeBox = listener }
            let handle = await t.addListener(listener: listener)
            await MainActor.run { self.bridgeHandle = handle }

            // Let the initial /context items arrive.
            try? await Task.sleep(nanoseconds: 300_000_000)

            var more = true
            var page = 0
            while more && page < 200 && !Task.isCancelled {
                more = (try? await t.paginateBackwards(numEvents: 100)) ?? false
                page += 1
                try? await Task.sleep(nanoseconds: 50_000_000)
                let count = await MainActor.run { self.bridgeItems.count }
                print("[Pagination:\(roomId)] bridge page \(page) – more=\(more) bridgeItems=\(count)")
                if !more { break }
            }

            // Merge items that aren't already in our timeline.
            await MainActor.run {
                for item in self.bridgeItems {
                    let uid = item.uniqueId().id
                    guard !self.historicalItems.contains(where: { $0.uniqueId().id == uid }) else { continue }
                    guard !self.sdkItems.contains(where: { $0.uniqueId().id == uid }) else { continue }
                    self.historicalItems.append(item)
                }
                var merged = self.historicalItems
                merged.removeAll { h in self.sdkItems.contains { $0.uniqueId().id == h.uniqueId().id } }
                merged.append(contentsOf: self.sdkItems)
                self.items = merged
            }
            let final = await MainActor.run { self.items.count }
            print("[Pagination:\(roomId)] bridge – done, total items now \(final)")
        } catch {
            print("[Pagination:\(roomId)] bridge – error: \(error)")
        }
        await MainActor.run {
            self.bridgeHandle = nil
            self.bridgeBox = nil
            self.bridgeTimeline = nil
            self.bridgeItems = []
        }
    }

    private func applyBridgeDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .reset(let v):            bridgeItems = v
            case .append(let v):           bridgeItems.append(contentsOf: v)
            case .pushBack(let v):         bridgeItems.append(v)
            case .pushFront(let v):        bridgeItems.insert(v, at: 0)
            case .insert(let i, let v):    bridgeItems.insert(v, at: min(Int(i), bridgeItems.count))
            case .set(let i, let v):
                let idx = Int(i)
                if idx < bridgeItems.count { bridgeItems[idx] = v } else { bridgeItems.append(v) }
            case .remove(let i):
                let idx = Int(i)
                if idx < bridgeItems.count { bridgeItems.remove(at: idx) }
            case .truncate(let l):
                if bridgeItems.count > Int(l) { bridgeItems.removeLast(bridgeItems.count - Int(l)) }
            case .clear:   bridgeItems = []
            case .popFront: if !bridgeItems.isEmpty { bridgeItems.removeFirst() }
            case .popBack:  if !bridgeItems.isEmpty { bridgeItems.removeLast() }
            }
        }
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
                canPaginate = true
                autoPaginateTask?.cancel()
                autoPaginateTask = nil
                startAutoPaginate()
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
                canPaginate = true
                autoPaginateTask?.cancel()
                autoPaginateTask = nil
                startAutoPaginate()
            }
        }
        
        // Rebuild public `items` to include both historical + live items without duplicates
        var newItems = historicalItems
        newItems.removeAll { histItem in
            sdkItems.contains(where: { $0.uniqueId().id == histItem.uniqueId().id })
        }
        newItems.append(contentsOf: sdkItems)
        items = newItems
    }

    // MARK: - Timeline actions

    func send(_ text: String) async {
        guard let timeline else { return }
        let msg: RoomMessageEventContentWithoutRelation
        switch SlashCommandParser.parse(text) {
        case .rainbow(let body):
            let pair = MessageBuilder.rainbow(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .spoiler(let body):
            let pair = MessageBuilder.spoiler(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .none:
            // Check for inline ||spoiler|| syntax (Discord-style)
            if text.contains("||") {
                let pair = MessageBuilder.inlineSpoilers(text)
                msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
            } else {
                // Plain markdown — SDK converts to HTML formatted_body automatically.
                msg = messageEventContentFromMarkdown(md: text)
            }
        }
        do {
            _ = try await timeline.send(msg: msg)
        } catch {
            session?.lastError = describe(error)
        }
    }

    func sendReply(to eventId: String, text: String) async {
        guard let timeline else { return }
        let msg: RoomMessageEventContentWithoutRelation
        switch SlashCommandParser.parse(text) {
        case .rainbow(let body):
            let pair = MessageBuilder.rainbow(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .spoiler(let body):
            let pair = MessageBuilder.spoiler(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .none:
            if text.contains("||") {
                let pair = MessageBuilder.inlineSpoilers(text)
                msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
            } else {
                msg = messageEventContentFromMarkdown(md: text)
            }
        }
        do {
            try await timeline.sendReply(msg: msg, eventId: eventId)
        } catch { session?.lastError = describe(error) }
    }

    func sendEdit(to eventId: String, text: String) async {
        guard let timeline else { return }
        let msg: RoomMessageEventContentWithoutRelation
        switch SlashCommandParser.parse(text) {
        case .rainbow(let body):
            let pair = MessageBuilder.rainbow(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .spoiler(let body):
            let pair = MessageBuilder.spoiler(body)
            msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
        case .none:
            if text.contains("||") {
                let pair = MessageBuilder.inlineSpoilers(text)
                msg = buildHTMLMessage(plain: pair.plain, html: pair.html)
            } else {
                msg = messageEventContentFromMarkdown(md: text)
            }
        }
        do {
            try await timeline.edit(eventOrTransactionId: .eventId(eventId: eventId), newContent: .roomMessage(content: msg))
        } catch { session?.lastError = describe(error) }
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

    /// Send one or more files (images, videos, or generic files) from local URLs.
    func sendAttachments(_ urls: [URL]) async {
        for url in urls {
            await sendAttachment(url)
        }
    }

    /// Send a single file attachment. Reads the file into memory to avoid
    /// security-scoped resource timing issues, then sends via the SDK.
    func sendAttachment(_ url: URL) async {
        guard let timeline else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let mime = mimeType(for: url)

        // Read file data into memory so the security-scoped resource doesn't
        // expire before the SDK's background upload finishes.
        guard let fileData = try? Data(contentsOf: url) else {
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
                let info = imageInfo(for: url, mime: mime)
                _ = try timeline.sendImage(params: params, thumbnailSource: nil, imageInfo: info)
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
        } catch {
            session?.lastError = describe(error)
        }
    }

    /// Send raw data (e.g. from clipboard paste or drag-and-drop).
    func sendData(_ data: Data, filename: String, mime: String) async {
        guard let timeline else { return }
        let params = UploadParameters(
            source: .data(bytes: data, filename: filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        do {
            if mime.hasPrefix("image/") {
                var info = ImageInfo(
                    height: nil, width: nil, mimetype: mime, size: UInt64(data.count),
                    thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil
                )
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    info.width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
                    info.height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
                }
                _ = try timeline.sendImage(params: params, thumbnailSource: nil, imageInfo: info)
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
        } catch {
            session?.lastError = describe(error)
        }
    }

    private func mimeType(for url: URL) -> String {
        if let uti = UTType(filenameExtension: url.pathExtension) {
            return uti.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    private func imageInfo(for url: URL, mime: String) -> ImageInfo {
        var w: UInt64?
        var h: UInt64?
        var size: UInt64?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
            h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.uint64Value
        }
        return ImageInfo(
            height: h, width: w, mimetype: mime, size: size,
            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil
        )
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
