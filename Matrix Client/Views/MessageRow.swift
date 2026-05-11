import SwiftUI
import AppKit
import MatrixRustSDK

/// One row of the timeline. Dispatches on `TimelineItem.asEvent()` vs `.asVirtual()`.
struct TimelineRow: View {
    let item: TimelineItem
    @ObservedObject var room: RoomVM
    let onReact: (String) -> Void
    let onQuickReact: (String, String) -> Void
    let onReply: (String) -> Void
    let onRedact: (String) -> Void
    let onTogglePin: (String) -> Void
    let onShowSource: () -> Void
    let onEditNickname: (String, String) -> Void

    var body: some View {
        if let virtual = item.asVirtual() {
            VirtualRow(virtual: virtual)
        } else if let event = item.asEvent() {
            EventRow(
                event: event,
                room: room,
                onReact: onReact,
                onQuickReact: onQuickReact,
                onReply: onReply,
                onRedact: onRedact,
                onTogglePin: onTogglePin,
                onShowSource: onShowSource,
                onEditNickname: onEditNickname
            )
        }
    }
}

private struct VirtualRow: View {
    let virtual: VirtualTimelineItem

    var body: some View {
        switch virtual {
        case .dateDivider(let ts):
            let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
            let df = makeDateFormatter()
            HStack {
                Spacer()
                Text(df.string(from: date))
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.vertical, 6)
        case .readMarker:
            HStack {
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
                Text("New").font(.caption2).foregroundStyle(.tint)
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .timelineStart:
            HStack {
                Spacer()
                Text("Start of room").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.doesRelativeDateFormatting = true
        return f
    }
}

private struct EventRow: View {
    let event: EventTimelineItem
    @ObservedObject var room: RoomVM
    let onReact: (String) -> Void
    let onQuickReact: (String, String) -> Void
    let onReply: (String) -> Void
    let onRedact: (String) -> Void
    let onTogglePin: (String) -> Void
    let onShowSource: () -> Void
    let onEditNickname: (String, String) -> Void

    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var nicknames: NicknameStore
    @State private var hovering = false
    @State private var spoilersRevealed = false

    private var eventId: String? {
        if case .eventId(let id) = event.eventOrTransactionId { return id }
        return nil
    }

    private var serverSenderName: String {
        if case .ready(let name, _, _) = event.senderProfile, let n = name { return n }
        return event.sender
    }

    /// Local nickname if set, otherwise the server-provided display name.
    private var senderName: String {
        nicknames.displayName(for: event.sender, fallback: serverSenderName)
    }

    private var senderAvatar: String? {
        if case .ready(_, _, let avatar) = event.senderProfile { return avatar }
        return nil
    }

    private var isPinned: Bool {
        guard let id = eventId else { return false }
        return room.pinnedEventIds.contains(id)
    }

    private var date: Date {
        Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000.0)
    }

    private var isOwn: Bool { event.isOwn }

    var body: some View {
        Group {
            switch event.content {
            case .msgLike(let content):
                messageRow(content: content)
            case .roomMembership(let userId, let userDisplayName, let change, _):
                stateLine(membershipLine(userId: userId, name: userDisplayName, change: change))
            case .profileChange(let displayName, let prev, _, _):
                let who = prev ?? "Someone"
                let line = displayName.map { "\(who) is now \($0)" } ?? "\(who) updated their profile"
                stateLine(line)
            case .state(_, let content):
                stateLine(stateSummary(content))
            case .failedToParseMessageLike(let type, _):
                stateLine("(unparseable \(type))")
            case .failedToParseState(let type, _, _):
                stateLine("(unparseable state \(type))")
            case .callInvite:
                stateLine("\(senderName) started a call")
            case .rtcNotification:
                stateLine("\(senderName) — call event")
            }
        }
        // Make the entire row hover-detectable, not just the content area.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    // MARK: - Message-like

    @ViewBuilder
    private func messageRow(content: MsgLikeContent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isOwn {
                // Right-aligned own message: spacer pushes content to the right.
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    senderLine
                    kindBody(content.kind, content: content, ownAlignment: .trailing)
                    reactionsRow(content.reactions, alignment: .trailing)
                }
                Avatar(name: senderName, mxc: senderAvatar, size: 32)
            } else {
                Avatar(name: senderName, mxc: senderAvatar, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    senderLine
                    kindBody(content.kind, content: content, ownAlignment: .leading)
                    reactionsRow(content.reactions, alignment: .leading)
                }
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(rowBackground)
        .overlay(alignment: .topTrailing) { hoverActionsOverlay }
        .contextMenu {
            Button("Set Nickname for \(serverSenderName)…") {
                onEditNickname(event.sender, serverSenderName)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isPinned {
            Color.yellow.opacity(0.08)
        } else if hovering {
            Color.secondary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    /// Pinned to the top-right of the row, visible whenever the cursor is anywhere over
    /// the row. Stable position — doesn't follow the cursor.
    @ViewBuilder
    private var hoverActionsOverlay: some View {
        if hovering, let eid = eventId {
            hoverActions(eid: eid)
                .padding(.top, 2)
                .padding(.trailing, 8)
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private func hoverActions(eid: String) -> some View {
        HStack(spacing: 4) {
            Button { onQuickReact(eid, "👍") } label: { Text("👍").font(.system(size: 13)) }
                .buttonStyle(.plain).help("React 👍")
            Button { onReact(eid) } label: { Image(systemName: "face.smiling") }
                .buttonStyle(.plain).help("React")
            Menu {
                if event.canBeRepliedTo {
                    Button("Reply") { onReply(eid) }
                }
                Button(isPinned ? "Unpin" : "Pin") { onTogglePin(eid) }
                Button("View Source", action: onShowSource)
                Button("Set Nickname for \(serverSenderName)…") {
                    onEditNickname(event.sender, serverSenderName)
                }
                if event.isOwn || event.isEditable {
                    Divider()
                    Button("Redact", role: .destructive) { onRedact(eid) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thickMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    @ViewBuilder
    private func kindBody(_ kind: MsgLikeKind, content: MsgLikeContent, ownAlignment: HorizontalAlignment) -> some View {
        switch kind {
        case .message(let msg):
            messageContent(msg, alignment: ownAlignment)
        case .sticker(let body, _, _):
            Text("🪧 Sticker: \(body)").italic().foregroundStyle(.secondary)
        case .poll(let question, _, _, _, _, _, _):
            Text("📊 Poll: \(question)").italic().foregroundStyle(.secondary)
        case .redacted:
            Text("(message deleted)").italic().foregroundStyle(.tertiary)
        case .unableToDecrypt(let msg):
            unableToDecryptRow(msg)
        case .other(let type):
            Text("(\(eventTypeLabel(type)))").italic().foregroundStyle(.tertiary)
        case .liveLocation:
            Text("📍 Live location").italic().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func messageContent(_ msg: MessageContent, alignment: HorizontalAlignment) -> some View {
        let bubbleAlignment: Alignment = (alignment == .trailing) ? .trailing : .leading
        switch msg.msgType {
        case .text(let t):
            renderableTextBody(
                attributed: MarkdownRenderer.render(body: t.body, formatted: t.formatted, revealSpoilers: spoilersRevealed),
                hasSpoilers: MarkdownRenderer.hasSpoilers(t.formatted),
                edited: msg.isEdited,
                alignment: bubbleAlignment
            )
        case .notice(let n):
            renderableTextBody(
                attributed: MarkdownRenderer.render(body: n.body, formatted: n.formatted, revealSpoilers: spoilersRevealed),
                hasSpoilers: MarkdownRenderer.hasSpoilers(n.formatted),
                edited: msg.isEdited,
                alignment: bubbleAlignment,
                secondary: true
            )
        case .emote(let e):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                (Text("* \(senderName) ").italic() + Text(MarkdownRenderer.render(body: e.body, formatted: e.formatted, revealSpoilers: spoilersRevealed)).italic())
            }
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .image(let img):
            VStack(alignment: alignment, spacing: 4) {
                Button(action: { downloadAndOpen(source: img.source, filename: img.filename) }) {
                    MxcImage(source: img.source, maxWidth: 360, maxHeight: 240)
                }
                .buttonStyle(.plain)
                if let cap = img.caption, !cap.isEmpty {
                    Text(cap).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .video(let v):
            attachmentChip(systemName: "play.rectangle.fill",
                           label: v.caption ?? v.filename,
                           source: v.source, filename: v.filename)
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .audio(let a):
            attachmentChip(systemName: "waveform",
                           label: a.caption ?? a.filename,
                           source: a.source, filename: a.filename)
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .file(let f):
            attachmentChip(systemName: "doc.fill",
                           label: f.caption ?? f.filename,
                           source: f.source, filename: f.filename)
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .gallery(let g):
            Text("🖼 Gallery (\(g.itemtypes.count) items)").italic().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .location(let l):
            Text("📍 \(l.body)").italic().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        case .other(_, let body):
            Text(body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: bubbleAlignment)
        }
    }

    @ViewBuilder
    private func attachmentChip(systemName: String, label: String,
                                 source: MediaSource, filename: String) -> some View {
        Button { downloadAndOpen(source: source, filename: filename) } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout.weight(.medium))
                    Text(filename).font(.caption2).foregroundStyle(.tertiary)
                }
                Image(systemName: "arrow.down.circle").foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Text body with optional spoiler tap-to-reveal. We always render via Text + AttributedString
    /// so inline HTML formatting (colors, bold, italic, links) survives — the only piece we
    /// don't fold into AttributedString is the tap target itself.
    @ViewBuilder
    private func renderableTextBody(attributed: AttributedString, hasSpoilers: Bool, edited: Bool, alignment: Alignment, secondary: Bool = false) -> some View {
        let textView = Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.blue)
        let styled: AnyView = secondary
            ? AnyView(textView.foregroundStyle(.secondary))
            : AnyView(textView)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if hasSpoilers {
                styled
                    .contentShape(Rectangle())
                    .onTapGesture { spoilersRevealed.toggle() }
                    .help(spoilersRevealed ? "Hide spoilers" : "Tap to reveal spoilers")
            } else {
                styled
            }
            if edited {
                Text("(edited)").font(.caption2).foregroundStyle(.secondary)
            }
            if hasSpoilers && !spoilersRevealed {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func unableToDecryptRow(_ msg: EncryptedMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text(decryptFailLabel(msg))
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private func decryptFailLabel(_ msg: EncryptedMessage) -> String {
        switch msg {
        case .megolmV1AesSha2(let sessionId, _):
            return "Encrypted (session \(sessionId.prefix(6))) — waiting for key"
        case .olmV1Curve25519AesSha2:
            return "Encrypted to-device message"
        case .unknown:
            return "Encrypted (unknown algorithm)"
        }
    }

    // MARK: - State + membership lines

    private func membershipLine(userId: String, name: String?, change: MembershipChange?) -> String {
        let who = nicknames.displayName(for: userId, fallback: name)
        guard let change else { return "\(who) updated membership" }
        switch change {
        case .joined: return "\(who) joined"
        case .left: return "\(who) left"
        case .invited: return "\(who) was invited"
        case .banned: return "\(who) was banned"
        case .unbanned: return "\(who) was unbanned"
        case .kicked: return "\(who) was kicked"
        case .kickedAndBanned: return "\(who) was kicked and banned"
        case .invitationAccepted: return "\(who) accepted the invite"
        case .invitationRejected: return "\(who) rejected the invite"
        case .invitationRevoked: return "Invite to \(who) was revoked"
        case .notImplemented, .none, .error: return "\(who) updated membership"
        case .knocked: return "\(who) knocked"
        case .knockAccepted: return "\(who) was admitted"
        case .knockRetracted: return "\(who) retracted their knock"
        case .knockDenied: return "\(who) was denied entry"
        }
    }

    private func stateSummary(_ s: OtherState) -> String {
        switch s {
        case .roomName(let name): return "Room name set to \(name ?? "—")"
        case .roomTopic(let topic): return "Room topic set to \(topic ?? "—")"
        case .roomAvatar: return "Room avatar updated"
        case .roomEncryption: return "Encryption enabled 🔒"
        case .roomCreate: return "Room created"
        case .roomPinnedEvents: return "Pinned messages updated"
        case .roomPowerLevels: return "Power levels updated"
        case .roomJoinRules: return "Join rules updated"
        case .roomGuestAccess: return "Guest access updated"
        case .roomHistoryVisibility: return "History visibility updated"
        case .custom(let type): return "(\(type))"
        default: return "Room state updated"
        }
    }

    @ViewBuilder
    private func stateLine(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text).font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu { Button("View Source", action: onShowSource) }
    }

    private func eventTypeLabel(_ t: MessageLikeEventType) -> String {
        switch t {
        case .roomMessage: return "message"
        case .roomEncrypted: return "encrypted"
        case .reaction: return "reaction"
        case .roomRedaction: return "redaction"
        case .sticker: return "sticker"
        default: return "event"
        }
    }

    // MARK: - Shared chrome

    private var senderLine: some View {
        HStack(spacing: 6) {
            if !isOwn {
                Text(senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(senderColor(for: event.sender))
                    .onTapGesture(count: 2) { onEditNickname(event.sender, serverSenderName) }
            }
            Text(timeFull(date))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if isOwn {
                Text("You")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(senderColor(for: event.sender))
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if let status = event.localSendState, !isSent(status) {
                Text("•").foregroundStyle(.tertiary)
                Text(sendStateLabel(status)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func reactionsRow(_ reactions: [Reaction], alignment: HorizontalAlignment) -> some View {
        if !reactions.isEmpty, let eid = eventId {
            let myId = session.currentUserId
            HStack {
                if alignment == .trailing { Spacer() }
                ReactionsBar(
                    reactions: reactions,
                    myUserId: myId,
                    onTap: { key in onQuickReact(eid, key) }
                )
                if alignment == .leading { Spacer() }
            }
            .padding(.top, 2)
        }
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

    private func isSent(_ s: EventSendState) -> Bool {
        if case .sent = s { return true }
        return false
    }

    private func sendStateLabel(_ s: EventSendState) -> String {
        switch s {
        case .notSentYet: return "sending"
        case .sendingFailed: return "failed"
        case .sent: return "sent"
        }
    }

    // MARK: - Download

    private func downloadAndOpen(source: MediaSource, filename: String) {
        guard let client = session.client else { return }
        Task {
            do {
                let handle = try await client.getMediaFile(
                    mediaSource: source,
                    filename: filename,
                    mimeType: "application/octet-stream",
                    useCache: true,
                    tempDir: nil
                )
                let path = try handle.path()
                await MainActor.run {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } catch {
                // Best-effort fallback: write raw bytes to a temp file.
                if let data = try? await client.getMediaContent(mediaSource: source) {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    let url = tmp.appendingPathComponent(filename)
                    try? data.write(to: url)
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
