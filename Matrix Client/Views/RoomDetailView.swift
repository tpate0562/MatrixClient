import SwiftUI

struct RoomDetailView: View {
    @ObservedObject var room: Room
    @EnvironmentObject private var session: MatrixSession
    @State private var draft: String = ""
    @State private var showAdmin = false
    @State private var showPins = false
    @State private var sourceEvent: MatrixEvent?
    @State private var emojiTargetEvent: MatrixEvent?
    @State private var replyingTo: MatrixEvent?

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
                .help("Pinned messages")
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
        .sheet(item: $sourceEvent) { ev in
            EventSourceView(event: ev)
        }
        .sheet(item: $emojiTargetEvent) { ev in
            EmojiPickerView { key in
                emojiTargetEvent = nil
                Task { await session.toggleReaction(roomId: room.id, targetEventId: ev.eventId, key: key) }
            }
        }
        .onAppear {
            Task { await session.sendReadReceipt(roomId: room.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(name: room.displayName, mxc: room.avatarMxc, size: 32)
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
            Text("\(room.joinedMemberCount) members")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var timeline: some View {
        let items = visibleItems()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items.indices, id: \.self) { idx in
                        let item = items[idx]
                        switch item {
                        case .dayHeader(let label):
                            HStack {
                                Spacer()
                                Text(label)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        case .event(let ev, let grouped):
                            MessageRow(
                                event: ev,
                                room: room,
                                groupedWithPrevious: grouped,
                                onReact: { emojiTargetEvent = ev },
                                onQuickReact: { key in
                                    Task { await session.toggleReaction(roomId: room.id, targetEventId: ev.eventId, key: key) }
                                },
                                onReply: { replyingTo = ev },
                                onRedact: {
                                    Task { await session.redact(roomId: room.id, eventId: ev.eventId) }
                                },
                                onPin: {
                                    Task { await session.togglePin(roomId: room.id, eventId: ev.eventId) }
                                },
                                onShowSource: { sourceEvent = ev }
                            )
                            .id(ev.eventId)
                        }
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: room.timeline.count) {
                withAnimation { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        MessageComposer(
            text: $draft,
            replyingTo: $replyingTo,
            isEncrypted: room.isEncrypted,
            room: room,
            onSend: send,
            onEmoji: { emojiTargetEvent = nil; showEmojiForCompose = true }
        )
        .sheet(isPresented: $showEmojiForCompose) {
            EmojiPickerView { key in
                showEmojiForCompose = false
                draft += key
            }
        }
    }

    @State private var showEmojiForCompose = false

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            await session.sendMessage(text, in: room.id)
            await session.sendReadReceipt(roomId: room.id)
        }
        replyingTo = nil
    }

    // Render plan with date dividers + grouping flags.
    private enum Item { case dayHeader(String); case event(MatrixEvent, grouped: Bool) }

    private func visibleItems() -> [Item] {
        var items: [Item] = []
        var lastDay: String?
        var lastSender: String?
        var lastTs: Int64 = 0
        let df = DateFormatter()
        df.dateStyle = .medium
        df.doesRelativeDateFormatting = true
        for ev in room.timeline where !room.redactedEventIds.contains(ev.eventId) {
            // Drop reactions; they're rendered under their target.
            if ev.type == "m.reaction" { continue }
            // Drop redaction events as their own row.
            if ev.type == "m.room.redaction" { continue }
            // Drop message edits (we'll fold the replacement in below).
            if ev.type == "m.room.message", ev.isEdit { continue }

            let day = df.string(from: ev.timestamp)
            if day != lastDay {
                items.append(.dayHeader(day))
                lastDay = day
                lastSender = nil
            }
            let grouped = ev.sender == lastSender && (ev.originServerTs - lastTs) < 5 * 60 * 1000
            items.append(.event(ev, grouped: grouped))
            lastSender = ev.sender
            lastTs = ev.originServerTs
        }
        return items
    }
}
