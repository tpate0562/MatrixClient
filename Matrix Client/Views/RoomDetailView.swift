import SwiftUI
import MatrixRustSDK

struct RoomDetailView: View {
    @ObservedObject var room: RoomVM
    @EnvironmentObject private var session: MatrixSession
    @State private var draft: String = ""
    @State private var showAdmin = false
    @State private var showPins = false
    @State private var sourceItem: TimelineItem?
    @State private var emojiTargetEventId: String?
    @State private var showEmojiForCompose = false
    @State private var replyingToId: String?
    @State private var nicknameTarget: NicknameTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timeline
            Divider()
            composer
        }
        .toolbar {
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
                LazyVStack(alignment: .leading, spacing: 11) {
                    paginationHeader
                    ForEach(room.items.indices, id: \.self) { idx in
                        let item = room.items[idx]
                        TimelineRow(
                            item: item,
                            room: room,
                            onReact: { id in emojiTargetEventId = id },
                            onQuickReact: { id, key in Task { await room.toggleReaction(targetEventId: id, key: key) } },
                            onReply: { id in replyingToId = id },
                            onRedact: { id in Task { await room.redact(eventId: id) } },
                            onTogglePin: { id in Task { await room.togglePin(eventId: id) } },
                            onShowSource: { sourceItem = item },
                            onEditNickname: editNickname
                        )
                        .id(item.uniqueId().id)
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: room.items.count) {
                withAnimation { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            typingIndicator
            MessageComposer(
                text: $draft,
                replyingToId: $replyingToId,
                room: room,
                onSend: send,
                onEmoji: { showEmojiForCompose = true }
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
        replyingToId = nil
        Task {
            if let replyTo {
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
