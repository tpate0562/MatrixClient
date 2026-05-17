import SwiftUI
import MatrixRustSDK
import UniformTypeIdentifiers

private enum SearchMode: String, CaseIterable {
    case exact = "Exact"
    case closest = "Best Match"
}

private func fuzzyScore(query: String, in text: String) -> Double {
    let q = query.lowercased(), t = text.lowercased()
    var qi = q.startIndex
    var matched = 0
    for ch in t {
        if qi < q.endIndex && ch == q[qi] {
            matched += 1
            qi = q.index(after: qi)
        }
    }
    return q.isEmpty ? 0 : Double(matched) / Double(q.count)
}

struct RoomDetailView: View {
    @ObservedObject var room: RoomVM
    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var reactionHistory: ReactionHistoryStore
    @State private var draft: String = ""
    @State private var showAdmin = false
    @State private var showPins = false
    @State private var sourceItem: TimelineItem?
    @State private var emojiTargetEventId: String?
    @State private var showEmojiForCompose = false
    @State private var replyingToId: String?
    @State private var editingId: String?
    @State private var editingOriginalBody: String = ""
    @State private var nicknameTarget: NicknameTarget?
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchMode: SearchMode = .exact
    @State private var showImportPicker = false
    // Only the newest `displayLimit` messages are built into the view tree;
    // scrolling to the top sentinel reveals another page.
    @State private var displayLimit: Int = 50
    @State private var loadingMoreWindow = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSearch { searchBar }
            Group {
                if showSearch && !searchQuery.isEmpty {
                    searchResultsView
                } else if !room.initialLoadComplete {
                    loadingView.transition(.opacity)
                } else {
                    timeline.transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: room.initialLoadComplete)
            Divider()
            composer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    displayLimit = 50
                    Task { await room.forceReload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Force reload messages (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { showSearch.toggle() }
                    if !showSearch { searchQuery = "" }
                } label: {
                    Label("Search", systemImage: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search messages (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showPins = true } label: {
                    Label("Pinned (\(room.pinnedEventIds.count))", systemImage: "pin")
                }
                .keyboardShortcut("p", modifiers: .command)
                .help("Pinned messages (⌘P)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import from Element…") { showImportPicker = true }
                    if room.cachedMessages.contains(where: \.isImported) {
                        Button("Clear Imported History", role: .destructive) { room.clearImport() }
                    }
                } label: {
                    Label("Import", systemImage: room.cachedMessages.contains(where: \.isImported)
                          ? "square.and.arrow.down.fill"
                          : "square.and.arrow.down")
                }
                .help("Import exported chat history")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdmin = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Room settings / admin")
            }
        }
        .sheet(isPresented: $showAdmin) {
            RoomAdminView(room: room)
        }
        .sheet(isPresented: $showPins) {
            PinnedEventsView(room: room)
        }
        .sheet(item: Binding(
            get: { sourceItem.map { SourceWrapper(item: $0) } },
            set: { sourceItem = $0?.item }
        )) { wrapper in
            EventSourceView(item: wrapper.item)
        }
        .sheet(item: Binding(
            get: { emojiTargetEventId.map { EmojiTarget(eventId: $0) } },
            set: { emojiTargetEventId = $0?.eventId }
        )) { target in
            EmojiPickerView { key in
                reactionHistory.record(key)
                emojiTargetEventId = nil
                Task { await room.toggleReaction(targetEventId: target.eventId, key: key) }
            }
        }
        .sheet(isPresented: $showEmojiForCompose) {
            EmojiPickerView { key in
                showEmojiForCompose = false
                draft += key
            }
        }
        .sheet(item: $nicknameTarget) { target in
            NicknameEditor(userId: target.userId, currentName: target.fallbackName)
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { room.loadImport(from: urls) }
        }
        .task(id: room.id) {
            await room.openTimeline()
            await room.markAsRead()
        }
    }

    private func editNickname(userId: String, name: String) {
        nicknameTarget = NicknameTarget(userId: userId, fallbackName: name)
    }

    // MARK: - Search

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search messages…", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Picker("", selection: $searchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button("Done") {
                    withAnimation { showSearch = false }
                    searchQuery = ""
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
        }
    }

    /// Search runs over the full, disk-backed message cache (entire history),
    /// not just what's currently loaded into the timeline window.
    private var searchResults: [RoomVM.CachedMessage] {
        guard !searchQuery.isEmpty else { return [] }
        let query = searchQuery.lowercased()
        let all = room.cachedMessages
        switch searchMode {
        case .exact:
            return all
                .filter { $0.body.lowercased().contains(query) }
                .sorted { $0.timestamp > $1.timestamp }
        case .closest:
            return all
                .compactMap { m -> (RoomVM.CachedMessage, Double)? in
                    let score = fuzzyScore(query: query, in: m.body)
                    return score >= 0.6 ? (m, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
    }

    private var searchResultsView: some View {
        let results = searchResults
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty {
                    Text("No results for \"\(searchQuery)\"")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity)
                } else {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s") · searched all history")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(results) { msg in
                        CachedMessageRow(message: msg, members: room.members,
                                         isGroupContinuation: false)
                            .id(msg.id)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(name: room.displayName, mxc: room.avatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(room.displayName).font(.headline)
                    if room.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("End-to-end encrypted")
                    }
                }
                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("\(room.joinedMembersCount) members")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// A merged, chronologically-ordered display list. Cached messages slot into the
    /// correct position by timestamp; when the SDK later loads the same event, the
    /// cached entry is replaced in-place (same stable ID = smooth SwiftUI diff).
    private var displayItems: [DisplayItem] {
        let liveIds = Set(room.items.compactMap { item -> String? in
            guard let event = item.asEvent(),
                  case .eventId(let eid) = event.eventOrTransactionId else { return nil }
            return eid
        })
        let orphans = room.cachedMessages
            .filter { !liveIds.contains($0.id) }
            .sorted { $0.timestamp < $1.timestamp }

        var result: [DisplayItem] = []
        var cacheIdx = 0
        for item in room.items {
            // Flush cached messages older than this live event.
            if let event = item.asEvent() {
                let ts = Int64(event.timestamp)
                while cacheIdx < orphans.count && orphans[cacheIdx].timestamp < ts {
                    result.append(.cached(orphans[cacheIdx]))
                    cacheIdx += 1
                }
            }
            result.append(.live(item))
        }
        // Any remaining orphans predate all SDK items (e.g. imported / pre-sync-wall history).
        while cacheIdx < orphans.count {
            result.append(.cached(orphans[cacheIdx]))
            cacheIdx += 1
        }
        // Guarantee unique `ForEach` identities — duplicate ids render as
        // undefined behavior (rows vanish / scroll jumps). Keep the last copy.
        var seen = Set<String>()
        var deduped: [DisplayItem] = []
        deduped.reserveCapacity(result.count)
        for item in result.reversed() where seen.insert(item.stableId).inserted {
            deduped.append(item)
        }
        return deduped.reversed()
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading messages…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        let allRows = displayItems
        let rows = allRows.count > displayLimit
            ? Array(allRows.suffix(displayLimit))
            : allRows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    paginationHeader
                    // Reaching the top of the in-RAM window pulls in the next
                    // page (older cached rows, then older from the server).
                    Color.clear.frame(height: 1)
                        .onAppear { loadMoreIfNeeded(total: allRows.count) }
                    ForEach(Array(rows.enumerated()), id: \.element.stableId) { idx, displayItem in
                        let grouped = isGroupContinuation(at: idx, in: rows)
                        switch displayItem {
                        case .live(let item):
                            TimelineRow(
                                item: item,
                                room: room,
                                isGroupContinuation: grouped,
                                onReact: { id in emojiTargetEventId = id },
                                onQuickReact: { id, key in
                                    reactionHistory.record(key)
                                    Task { await room.toggleReaction(targetEventId: id, key: key) }
                                },
                                onReply: { id in replyingToId = id },
                                onRedact: { id in Task { await room.redact(eventId: id) } },
                                onTogglePin: { id in Task { await room.togglePin(eventId: id) } },
                                onShowSource: { sourceItem = item },
                                onEditNickname: editNickname,
                                onEdit: { id, body in
                                    replyingToId = nil
                                    editingId = id
                                    editingOriginalBody = body
                                    draft = body
                                }
                            )
                            .id(displayItem.stableId)
                            .padding(.top, grouped ? 1 : 8)
                        case .cached(let msg):
                            CachedMessageRow(message: msg, members: room.members,
                                             isGroupContinuation: grouped)
                                .id(displayItem.stableId)
                                .padding(.top, grouped ? 1 : 8)
                        }
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            // `defaultScrollAnchor(.bottom)` keeps the view pinned to the
            // newest message as content size changes — crucially while row
            // heights settle async (images / markdown / link previews) and as
            // new messages arrive. The explicit `scrollTo` kick is still
            // needed because a LazyVStack won't materialize its rows under
            // `defaultScrollAnchor` alone until something scrolls it.
            .defaultScrollAnchor(.bottom)
            .onAppear { jumpToBottom(proxy) }
            .onChange(of: room.initialLoadComplete) { _, done in
                if done { jumpToBottom(proxy) }
            }
        }
    }

    /// Force the LazyVStack to materialize and snap to the newest message.
    /// Retried over ~1 s, non-animated, because rows build lazily and their
    /// heights keep growing as async content (images, link previews) loads.
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        func go() { proxy.scrollTo("__bottom__", anchor: .bottom) }
        go()
        for delay in [0.0, 0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go)
        }
    }

    /// Grow the in-RAM window, or paginate older history from the server once
    /// the window already covers everything that's loaded.
    private func loadMoreIfNeeded(total: Int) {
        guard !loadingMoreWindow else { return }
        if displayLimit < total {
            loadingMoreWindow = true
            displayLimit += 50
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                loadingMoreWindow = false
            }
        } else if room.canPaginate && !room.paginating {
            loadingMoreWindow = true
            Task {
                await room.paginate()
                loadingMoreWindow = false
            }
        }
    }

    private func isGroupContinuation(at idx: Int, in rows: [DisplayItem]) -> Bool {
        guard idx > 0 else { return false }
        let cur = rows[idx]; let prev = rows[idx - 1]
        guard cur.isMsgLike, prev.isMsgLike else { return false }
        guard let curSender = cur.groupSender, let curTs = cur.groupTimestamp,
              let prevSender = prev.groupSender, let prevTs = prev.groupTimestamp else { return false }
        guard curSender == prevSender else { return false }
        return abs(curTs - prevTs) < 5 * 60 * 1000
    }

    private var composer: some View {
        VStack(spacing: 0) {
            typingIndicator
            MessageComposer(
                text: $draft,
                replyingToId: $replyingToId,
                editingId: $editingId,
                room: room,
                onSend: send,
                onEmoji: { showEmojiForCompose = true },
                onAttach: { urls in
                    Task { await room.sendAttachments(urls) }
                },
                onPasteData: { data, filename, mime in
                    Task { await room.sendData(data, filename: filename, mime: mime) }
                }
            )
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if !room.typingUserIds.isEmpty {
            HStack(spacing: 6) {
                TypingDots()
                Text(typingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .transition(.opacity)
        }
    }

    private var typingText: String {
        let names = room.typingUserIds.map { room.members[$0]?.displayName ?? $0 }.sorted()
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more are typing…"
        }
    }

    private var paginationHeader: some View {
        HStack {
            Spacer()
            if room.paginating {
                ProgressView().controlSize(.small)
                Text("Loading older messages…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if room.canPaginate {
                // Auto-pagination should normally kick in on its own; expose a button
                // anyway in case it's been paused.
                Button("Load older messages") {
                    room.startAutoPaginate()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Text("Start of history")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let replyTo = replyingToId
        let editTarget = editingId
        let originalBody = editingOriginalBody
        replyingToId = nil
        editingId = nil
        editingOriginalBody = ""
        Task {
            if let editTarget {
                // Skip the edit if the content didn't actually change.
                if text != originalBody.trimmingCharacters(in: .whitespacesAndNewlines) {
                    await room.sendEdit(to: editTarget, text: text)
                }
            } else if let replyTo {
                await room.sendReply(to: replyTo, text: text)
            } else {
                await room.send(text)
            }
            await room.markAsRead()
        }
    }
}

private struct EmojiTarget: Identifiable {
    let eventId: String
    var id: String { eventId }
}

private struct TypingDots: View {
    @State private var phase: Int = 0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                Task { @MainActor in phase = (phase + 1) % 3 }
            }
        }
    }
}

private struct SourceWrapper: Identifiable {
    let item: TimelineItem
    var id: String { item.uniqueId().id }
}

struct NicknameTarget: Identifiable {
    let userId: String
    let fallbackName: String
    var id: String { userId }
}

// MARK: - DisplayItem

/// Unified timeline entry — either a live SDK item or a cached/imported message.
enum DisplayItem {
    case live(TimelineItem)
    case cached(RoomVM.CachedMessage)

    /// Stable ID used for ForEach identity. Uses event_id for both sides so a cached
    /// entry transitions to the live SDK entry in-place rather than remove+insert.
    var stableId: String {
        switch self {
        case .live(let item):
            if let event = item.asEvent(),
               case .eventId(let eid) = event.eventOrTransactionId { return eid }
            return item.uniqueId().id
        case .cached(let m): return m.id
        }
    }

    var groupSender: String? {
        switch self {
        case .live(let item):  return item.asEvent()?.sender
        case .cached(let m):   return m.sender
        }
    }

    var groupTimestamp: Int64? {
        switch self {
        case .live(let item):
            guard let event = item.asEvent() else { return nil }
            return Int64(event.timestamp)
        case .cached(let m): return m.timestamp
        }
    }

    var isMsgLike: Bool {
        switch self {
        case .live(let item):
            guard let event = item.asEvent() else { return false }
            if case .msgLike = event.content { return true }
            return false
        case .cached: return true
        }
    }
}

// MARK: - CachedMessageRow

private struct CachedMessageRow: View {
    let message: RoomVM.CachedMessage
    let members: [String: RoomMember]
    var isGroupContinuation: Bool = false

    private var displayName: String {
        // Prefer the cached display name (from senderProfile at fetch time),
        // then members lookup, then MXID localpart.
        if let n = message.senderName { return n }
        if let n = members[message.sender]?.displayName { return n }
        return String(message.sender.split(separator: ":").first?.dropFirst()
            ?? Substring(message.sender))
    }

    private var avatarUrl: String? {
        message.senderAvatar ?? members[message.sender]?.avatarUrl
    }

    private func senderColor(for userId: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo, .mint, .cyan]
        var hash = 0
        for u in userId.unicodeScalars { hash = hash &+ Int(u.value) }
        return palette[abs(hash) % palette.count]
    }

    private func timeFull(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isGroupContinuation {
                Avatar(name: displayName, mxc: avatarUrl, size: 32)
            } else {
                Color.clear.frame(width: 32, height: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                if !isGroupContinuation {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(senderColor(for: message.sender))
                        Text(timeFull(message.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        if message.isImported {
                            Image(systemName: "archivebox")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .help("Imported from Element export")
                        }
                    }
                }
                Text(message.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 60)
        }
        .padding(.vertical, isGroupContinuation ? 0 : 1)
        .padding(.horizontal, 4)
    }
}
