import SwiftUI
import MatrixRustSDK

struct PinnedEventsView: View {
    @ObservedObject var room: RoomVM
    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var nicknames: NicknameStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PinnedEventsVM

    init(room: RoomVM) {
        self.room = room
        _vm = StateObject(wrappedValue: PinnedEventsVM(room: room.room))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pinned Messages").font(.headline)
                if vm.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if let error = vm.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text("Couldn't load pinned messages").foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if vm.items.isEmpty && !vm.loading {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No pinned messages").foregroundStyle(.secondary)
                    Text("Pin a message from its row menu.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.items.indices, id: \.self) { idx in
                            let item = vm.items[idx]
                            if let event = item.asEvent() {
                                PinnedRow(event: event, room: room, onUnpin: { id in
                                    Task { await room.unpin(eventId: id) }
                                })
                                .id(item.uniqueId().id)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 640, height: 540)
        .task(id: room.pinnedEventIds) { await vm.open(eventIds: room.pinnedEventIds) }
        .onDisappear { vm.close() }
    }
}

private struct PinnedRow: View {
    let event: EventTimelineItem
    @ObservedObject var room: RoomVM
    let onUnpin: (String) -> Void

    @EnvironmentObject private var nicknames: NicknameStore

    private var eventId: String? {
        if case .eventId(let id) = event.eventOrTransactionId { return id }
        return nil
    }

    private var senderName: String {
        let serverName: String
        if case .ready(let name, _, _) = event.senderProfile, let n = name {
            serverName = n
        } else {
            serverName = event.sender
        }
        return nicknames.displayName(for: event.sender, fallback: serverName)
    }

    private var senderAvatar: String? {
        if case .ready(_, _, let avatar) = event.senderProfile { return avatar }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: senderName, mxc: senderAvatar, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(senderName).font(.callout.bold())
                    Text(timeStr).font(.caption2).foregroundStyle(.tertiary)
                }
                bodyView
            }
            Spacer()
            if let id = eventId {
                Button { onUnpin(id) } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .help("Unpin")
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch event.content {
        case .msgLike(let content):
            switch content.kind {
            case .message(let msg):
                switch msg.msgType {
                case .text(let t):
                    Text(MarkdownRenderer.flatten(MarkdownRenderer.render(body: t.body, formatted: t.formatted, revealedSpoilers: []).segments))
                        .textSelection(.enabled)
                case .notice(let n):
                    Text(MarkdownRenderer.flatten(MarkdownRenderer.render(body: n.body, formatted: n.formatted, revealedSpoilers: []).segments))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case .emote(let e):
                    Text("* \(senderName) ").italic()
                        + Text(MarkdownRenderer.flatten(MarkdownRenderer.render(body: e.body, formatted: e.formatted, revealedSpoilers: []).segments)).italic()
                case .image(let img):
                    Text("🖼 \(img.caption ?? img.filename)").foregroundStyle(.secondary)
                case .file(let f):
                    Text("📎 \(f.filename)").foregroundStyle(.secondary)
                default:
                    Text("(\(msg.body))").foregroundStyle(.secondary)
                }
            case .redacted:
                Text("(message deleted)").italic().foregroundStyle(.tertiary)
            case .unableToDecrypt:
                Text("🔒 Encrypted — not decrypted").italic().foregroundStyle(.secondary)
            default:
                Text("(unsupported)").foregroundStyle(.tertiary)
            }
        default:
            Text("(non-message event)").foregroundStyle(.tertiary)
        }
    }

    private var timeStr: String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000.0)
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
}
