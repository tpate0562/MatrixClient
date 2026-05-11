import SwiftUI

/// Renders the pinned event ids from RoomInfo. Tapping unpin removes via Timeline.unpinEvent.
struct PinnedEventsView: View {
    @ObservedObject var room: RoomVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pinned Messages").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if room.pinnedEventIds.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No pinned messages").foregroundStyle(.secondary)
                    Text("Pin a message from its row menu.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(room.pinnedEventIds, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id).font(.caption.monospaced())
                                if let preview = preview(for: id) {
                                    Text(preview).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await room.unpin(eventId: id) }
                            } label: { Image(systemName: "pin.slash") }
                            .help("Unpin")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 600, height: 480)
    }

    /// Try to find a body for the event by scanning the current timeline. May be nil if
    /// the message isn't in our cached window — that's fine, we still show the ID.
    private func preview(for id: String) -> String? {
        for item in room.pinnedEventCandidates() {
            if let body = item.bodyForEventId(id) { return body }
        }
        return nil
    }
}

import MatrixRustSDK

extension RoomVM {
    fileprivate func pinnedEventCandidates() -> [TimelineItem] { items }
}

extension TimelineItem {
    fileprivate func bodyForEventId(_ targetId: String) -> String? {
        guard let event = asEvent() else { return nil }
        if case .eventId(let id) = event.eventOrTransactionId, id == targetId {
            if case .msgLike(let content) = event.content,
               case .message(let msg) = content.kind {
                return msg.body
            }
        }
        return nil
    }
}
