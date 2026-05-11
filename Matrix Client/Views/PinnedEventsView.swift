import SwiftUI

struct PinnedEventsView: View {
    @ObservedObject var room: Room
    @EnvironmentObject private var session: MatrixSession
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
            if pinnedEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No pinned messages").foregroundStyle(.secondary)
                    Text("Right-click any message and choose Pin.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(pinnedEvents, id: \.eventId) { ev in
                        HStack(alignment: .top, spacing: 8) {
                            Avatar(name: room.memberDisplayName(ev.sender) ?? ev.sender,
                                   mxc: room.memberAvatar(ev.sender), size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.memberDisplayName(ev.sender) ?? ev.sender)
                                    .font(.callout.bold())
                                Text(ev.messageBody ?? "(\(ev.type))")
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                Task { await session.togglePin(roomId: room.id, eventId: ev.eventId) }
                            } label: {
                                Image(systemName: "pin.slash")
                            }
                            .help("Unpin")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 600, height: 480)
    }

    private var pinnedEvents: [MatrixEvent] {
        room.pinnedEventIds.compactMap { id in
            room.timeline.first(where: { $0.eventId == id })
        }
    }
}
