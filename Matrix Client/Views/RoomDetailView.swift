import SwiftUI
import MatrixRustSDK

private enum SearchMode: String, CaseIterable {
    case exact = "Exact"
    case closest = "Best Match"
}

private func messageText(from item: TimelineItem) -> String? {
    guard let event = item.asEvent(),
          case .msgLike(let content) = event.content,
          case .message(let msg) = content.kind,
          case .text(let t) = msg.msgType else { return nil }
    return t.body
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSearch { searchBar }
            if showSearch && !searchQuery.isEmpty {
                searchResultsView
            } else {
                timeline
            }
            Divider()
            composer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
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

    private var searchResults: [TimelineItem] {
        guard !searchQuery.isEmpty else { return [] }
        let query = searchQuery.lowercased()
        switch searchMode {
        case .exact:
            return room.items.filter { item in
                guard let text = messageText(from: item) else { return false }
                return text.lowercased().contains(query)
            }
        case .closest:
            return room.items
                .compactMap { item -> (TimelineItem, Double)? in
                    guard let text = messageText(from: item) else { return nil }
                    let score = fuzzyScore(query: query, in: text)
                    return score >= 0.6 ? (item, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
    }

    private var searchResultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searchResults.isEmpty {
                    Text("No results for \"\(searchQuery)\"")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity)
                } else {
                    Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(searchResults.indices, id: \.self) { idx in
                        let item = searchResults[idx]
                        TimelineRow(
                            item: item,
                            room: room,
                            isGroupContinuation: false,
                            onReact: { id in emojiTargetEventId = id },
                            onQuickReact: { id, key in
                                reactionHistory.record(key)
                                Task { await room.toggleReaction(targetEventId: id, key: key) }
                            },
                            onReply: { id in replyingToId = id; withAnimation { showSearch = false }; searchQuery = "" },
                            onRedact: { id in Task { await room.redact(eventId: id) } },
                            onTogglePin: { id in Task { await room.togglePin(eventId: id) } },
                            onShowSource: { sourceItem = item },
                            onEditNickname: editNickname,
                            onEdit: { id, body in
                                replyingToId = nil
                                editingId = id
                                editingOriginalBody = body
                                draft = body
                                withAnimation { showSearch = false }
                                searchQuery = ""
                            }
                        )
                        .id(item.uniqueId().id)
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

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    paginationHeader
                    ForEach(room.items.indices, id: \.self) { idx in
                        let item = room.items[idx]
                        let grouped = isGroupContinuation(at: idx)
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
                        .id(item.uniqueId().id)
                        .padding(.top, grouped ? 1 : 8)
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: room.items.last?.uniqueId().id) {
                // Only scroll to the bottom when a new message arrives at the tail.
                // Pagination prepends older items, so the last item ID stays the same — skip those.
                withAnimation { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    /// Determine if `items[idx]` should be grouped with the previous message
    /// (same sender, both are message-like events, within 5 minutes).
    private func isGroupContinuation(at idx: Int) -> Bool {
        guard idx > 0 else { return false }
        let current = room.items[idx]
        let previous = room.items[idx - 1]
        guard let curEvent = current.asEvent(),
              let prevEvent = previous.asEvent() else { return false }
        // Only group message-like events
        guard case .msgLike = curEvent.content,
              case .msgLike = prevEvent.content else { return false }
        // Same sender
        guard curEvent.sender == prevEvent.sender else { return false }
        // Within 5 minutes
        let gap = abs(Int64(curEvent.timestamp) - Int64(prevEvent.timestamp))
        return gap < 5 * 60 * 1000  // 5 min in milliseconds
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

    @ViewBuilder
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
