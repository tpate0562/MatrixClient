import SwiftUI

struct MessageRow: View {
    let event: MatrixEvent
    @ObservedObject var room: Room
    let groupedWithPrevious: Bool
    let onReact: () -> Void
    let onQuickReact: (String) -> Void
    let onReply: () -> Void
    let onRedact: () -> Void
    let onPin: () -> Void
    let onShowSource: () -> Void

    @EnvironmentObject private var session: MatrixSession
    @State private var hovering = false

    private var senderName: String {
        room.memberDisplayName(event.sender) ?? event.sender
    }

    private var senderAvatar: String? { room.memberAvatar(event.sender) }

    private var isMine: Bool { event.sender == session.currentUserId }

    private var isPinned: Bool { room.pinnedEventIds.contains(event.eventId) }

    // If this event was edited, show the latest replacement body.
    private var effectiveBody: String? {
        let latest = room.timeline
            .filter { $0.isEdit && $0.replacesEventId == event.eventId }
            .max(by: { $0.originServerTs < $1.originServerTs })
        if let latest, let newBody = latest.newContent?["body"]?.stringValue {
            return newBody
        }
        return event.messageBody
    }

    private var wasEdited: Bool {
        room.timeline.contains { $0.isEdit && $0.replacesEventId == event.eventId }
    }

    var body: some View {
        Group {
            switch event.type {
            case "m.room.message": messageRow
            case "m.room.encrypted": encryptedRow
            case "m.room.member": memberStateRow
            case "m.room.name", "m.room.topic", "m.room.avatar",
                 "m.room.canonical_alias", "m.room.power_levels",
                 "m.room.pinned_events", "m.room.encryption",
                 "m.room.history_visibility", "m.room.guest_access",
                 "m.room.join_rules", "m.room.create":
                stateRow
            default: unknownRow
            }
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }

    // MARK: - Variants

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 8) {
            leftGutter
            VStack(alignment: .leading, spacing: 2) {
                if !groupedWithPrevious { senderLine }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(effectiveBody ?? "")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if wasEdited {
                        Text("(edited)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                reactionsRow
            }
            Spacer()
            trailingActions
        }
        .padding(.vertical, 1)
        .background(
            isPinned ? Color.yellow.opacity(0.08) : (hovering ? Color.secondary.opacity(0.05) : Color.clear)
        )
    }

    private var encryptedRow: some View {
        HStack(alignment: .top, spacing: 8) {
            leftGutter
            VStack(alignment: .leading, spacing: 2) {
                if !groupedWithPrevious { senderLine }
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("Encrypted message — decryption not supported in this client")
                        .foregroundStyle(.secondary)
                        .italic()
                }
                reactionsRow
            }
            Spacer()
            trailingActions
        }
        .background(hovering ? Color.secondary.opacity(0.05) : Color.clear)
    }

    private var memberStateRow: some View {
        let membership = event.content["membership"]?.stringValue ?? "?"
        let target = event.stateKey ?? ""
        let targetName = room.memberDisplayName(target) ?? target
        let actorName = room.memberDisplayName(event.sender) ?? event.sender
        let line: String = {
            switch membership {
            case "join":   return "\(targetName) joined"
            case "leave":  return target == event.sender ? "\(targetName) left" : "\(actorName) removed \(targetName)"
            case "invite": return "\(actorName) invited \(targetName)"
            case "ban":    return "\(actorName) banned \(targetName)"
            default:       return "\(targetName) — \(membership)"
            }
        }()
        return HStack {
            Spacer()
            Text(line)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu { Button("View Source") { onShowSource() } }
    }

    private var stateRow: some View {
        HStack {
            Spacer()
            Text(stateSummary())
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu { Button("View Source") { onShowSource() } }
    }

    private var unknownRow: some View {
        HStack {
            Spacer()
            Text("\(event.type) by \(event.sender)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu { Button("View Source") { onShowSource() } }
    }

    private func stateSummary() -> String {
        let actor = room.memberDisplayName(event.sender) ?? event.sender
        switch event.type {
        case "m.room.name":     return "\(actor) set the room name"
        case "m.room.topic":    return "\(actor) set the room topic"
        case "m.room.avatar":   return "\(actor) changed the room avatar"
        case "m.room.encryption": return "\(actor) turned on encryption 🔒"
        case "m.room.pinned_events": return "\(actor) updated pinned messages"
        case "m.room.power_levels":  return "\(actor) updated power levels"
        case "m.room.create":   return "Room created"
        default: return event.type
        }
    }

    // MARK: - Shared pieces

    private var leftGutter: some View {
        Group {
            if groupedWithPrevious {
                Color.clear.frame(width: 32, height: 1)
                    .overlay(alignment: .leading) {
                        Text(timeShort(event.timestamp))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                            .frame(width: 32, alignment: .center)
                    }
            } else {
                Avatar(name: senderName, mxc: senderAvatar, size: 32)
            }
        }
    }

    private var senderLine: some View {
        HStack(spacing: 6) {
            Text(senderName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(senderColor(for: event.sender))
            Text(timeFull(event.timestamp))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var reactionsRow: some View {
        let reactions = room.reactionsByTarget[event.eventId] ?? []
        if !reactions.isEmpty {
            ReactionsBar(
                reactions: reactions,
                myUserId: session.currentUserId,
                onTap: { key in onQuickReact(key) }
            )
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if hovering {
            HStack(spacing: 4) {
                Button { onQuickReact("👍") } label: { Text("👍") }
                    .buttonStyle(.plain).help("React 👍")
                Button { onReact() } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(.plain).help("React")
                Menu {
                    Button("Reply", action: onReply)
                    Button(isPinned ? "Unpin" : "Pin", action: onPin)
                    Button("View Source", action: onShowSource)
                    if isMine {
                        Divider()
                        Button("Redact", role: .destructive, action: onRedact)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
            .padding(.trailing, 4)
        }
    }

    private func timeShort(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func timeFull(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
    }

    private func senderColor(for userId: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo, .mint, .cyan]
        var hash = 0
        for u in userId.unicodeScalars { hash = hash &+ Int(u.value) }
        return palette[abs(hash) % palette.count]
    }
}
