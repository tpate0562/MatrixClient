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
                messageBodyView
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

    @ViewBuilder
    private var messageBodyView: some View {
        let mt = event.msgType
        switch mt {
        case "m.image":   imageAttachment
        case "m.video":   videoAttachment
        case "m.audio":   audioAttachment
        case "m.file":    fileAttachment
        case "m.emote":
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("*")
                    .foregroundStyle(.tertiary)
                Text((effectiveBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    .italic()
                    .textSelection(.enabled)
                if wasEdited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
            }
        case "m.notice":
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(effectiveBody ?? "")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if wasEdited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(effectiveBody ?? "")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if wasEdited { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var attachmentMxc: String? {
        // For unencrypted attachments the URL is in content.url; for encrypted attachments it's
        // in content.file.url (and the payload is symmetrically encrypted — we can't decrypt yet).
        event.content["url"]?.stringValue ?? event.content["file"]?["url"]?.stringValue
    }

    private var attachmentIsEncrypted: Bool {
        event.content["file"]?["url"] != nil
    }

    private var imageAttachment: some View {
        VStack(alignment: .leading, spacing: 4) {
            if attachmentIsEncrypted {
                lockedAttachmentRow("Encrypted image")
            } else {
                Button {
                    openAttachment()
                } label: {
                    MxcImage(mxc: attachmentMxc, maxWidth: 360, maxHeight: 240)
                }
                .buttonStyle(.plain)
                .help(event.messageBody ?? "Image")
            }
            if let body = event.messageBody, !body.isEmpty {
                Text(body).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var videoAttachment: some View {
        attachmentChip(systemName: "play.rectangle.fill", label: event.messageBody ?? "Video")
    }

    private var audioAttachment: some View {
        attachmentChip(systemName: "waveform", label: event.messageBody ?? "Audio")
    }

    private var fileAttachment: some View {
        attachmentChip(systemName: "doc.fill", label: event.content["filename"]?.stringValue ?? event.messageBody ?? "File")
    }

    @ViewBuilder
    private func attachmentChip(systemName: String, label: String) -> some View {
        if attachmentIsEncrypted {
            lockedAttachmentRow(label)
        } else {
            Button(action: openAttachment) {
                HStack(spacing: 8) {
                    Image(systemName: systemName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.callout.weight(.medium))
                        if let size = event.content["info"]?["size"]?.intValue {
                            Text(formatBytes(size)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func lockedAttachmentRow(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("\(label) — encrypted, can't open")
                .foregroundStyle(.secondary).italic()
        }
    }

    private func openAttachment() {
        guard let mxc = attachmentMxc,
              let creds = session.credentials else { return }
        let api = session.api
        Task {
            guard let url = await api.mediaURL(homeserver: creds.homeserverURL, mxc: mxc) else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let suggestedName = event.content["filename"]?.stringValue ?? event.messageBody ?? (response.suggestedFilename ?? "download")
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(suggestedName)
                try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: tmp)
                await MainActor.run { NSWorkspace.shared.open(tmp) }
            } catch {
                // Silently ignore for now; could surface to lastError.
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private var encryptedRow: some View {
        HStack(alignment: .top, spacing: 8) {
            leftGutter
            VStack(alignment: .leading, spacing: 2) {
                if !groupedWithPrevious { senderLine }
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("Encrypted message")
                        .foregroundStyle(.secondary)
                        .italic()
                    if let algo = event.content["algorithm"]?.stringValue {
                        Text("· \(algoShort(algo))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if let sid = event.content["session_id"]?.stringValue {
                        Text("· session \(sid.prefix(6))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .help("Session ID: \(sid)")
                    }
                }
                reactionsRow
            }
            Spacer()
            trailingActions
        }
        .background(hovering ? Color.secondary.opacity(0.05) : Color.clear)
    }

    private func algoShort(_ s: String) -> String {
        switch s {
        case "m.megolm.v1.aes-sha2": return "megolm v1"
        case "m.olm.v1.curve25519-aes-sha2": return "olm v1"
        default: return s
        }
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
