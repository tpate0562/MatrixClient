import SwiftUI
import AppKit
import MatrixRustSDK

/// One row of the timeline. Dispatches on `TimelineItem.asEvent()` vs `.asVirtual()`.
struct TimelineRow: View {
    let item: TimelineItem
    @ObservedObject var room: RoomVM
    var isGroupContinuation: Bool = false

    let onReact: (String) -> Void
    let onQuickReact: (String, String) -> Void
    let onReply: (String) -> Void
    let onRedact: (String) -> Void
    let onTogglePin: (String) -> Void
    let onShowSource: () -> Void
    let onEditNickname: (String, String) -> Void
    let onEdit: (String, String) -> Void

    var body: some View {
        if let virtual = item.asVirtual() {
            VirtualRow(virtual: virtual)
        } else if let event = item.asEvent() {
            EventRow(
                event: event,
                room: room,
                isGroupContinuation: isGroupContinuation,
                onReact: onReact,
                onQuickReact: onQuickReact,
                onReply: onReply,
                onRedact: onRedact,
                onTogglePin: onTogglePin,
                onShowSource: onShowSource,
                onEditNickname: onEditNickname,
                onEdit: onEdit
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
    var isGroupContinuation: Bool = false
    let onReact: (String) -> Void
    let onQuickReact: (String, String) -> Void
    let onReply: (String) -> Void
    let onRedact: (String) -> Void
    let onTogglePin: (String) -> Void
    let onShowSource: () -> Void
    let onEditNickname: (String, String) -> Void
    let onEdit: (String, String) -> Void

    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var nicknames: NicknameStore
    @EnvironmentObject private var reactionHistory: ReactionHistoryStore
    @State private var hovering = false
    @State private var revealedSpoilers: Set<Int> = []

    private var eventId: String? {
        if case .eventId(let id) = event.eventOrTransactionId { return id }
        return nil
    }

    /// Transaction id of a local echo that hasn't successfully sent yet
    /// (still "sending" or send-failed) — i.e. something we can still cancel.
    private var pendingTransactionId: String? {
        guard let state = event.localSendState, !isSent(state) else { return nil }
        if case .transactionId(let tx) = event.eventOrTransactionId { return tx }
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

    private var rawBody: String? {
        if case .msgLike(let content) = event.content,
           case .message(let msg) = content.kind,
           case .text(let txt) = msg.msgType {
            return txt.body
        }
        return nil
    }

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
                    if !isGroupContinuation { senderLine }
                    replyPreview(content.inReplyTo, alignment: .trailing)
                    HStack(alignment: .bottom, spacing: 4) {
                        if isGroupContinuation { continuationTimeLine }
                        kindBody(content.kind, content: content, ownAlignment: .trailing)
                    }
                    reactionsRow(content.reactions, alignment: .trailing)
                    readReceiptsRow(alignment: .trailing)
                }
                if !isGroupContinuation {
                    Avatar(name: senderName, mxc: senderAvatar, size: 32)
                } else {
                    Color.clear.frame(width: 32, height: 0)
                }
            } else {
                if !isGroupContinuation {
                    Avatar(name: senderName, mxc: senderAvatar, size: 32)
                } else {
                    Color.clear.frame(width: 32, height: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !isGroupContinuation { senderLine }
                    replyPreview(content.inReplyTo, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 4) {
                        kindBody(content.kind, content: content, ownAlignment: .leading)
                        if isGroupContinuation { continuationTimeLine }
                    }
                    reactionsRow(content.reactions, alignment: .leading)
                    readReceiptsRow(alignment: .leading)
                }
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, isGroupContinuation ? 0 : 1)
        .padding(.horizontal, 4)
        .background(rowBackground)
        .overlay(alignment: isOwn ? .topLeading : .topTrailing) { hoverActionsOverlay }
        .contextMenu {
            if let tx = pendingTransactionId {
                Button("Discard Unsent Message", role: .destructive) {
                    Task { await room.cancelSend(transactionId: tx) }
                }
                Divider()
            }
            if let eid = eventId {
                if event.canBeRepliedTo {
                    Button("Reply") { onReply(eid) }
                }
                Button(isPinned ? "Unpin" : "Pin") { onTogglePin(eid) }
                Divider()
                Button("View Source", action: onShowSource)
                Button("Set Nickname for \(serverSenderName)…") {
                    onEditNickname(event.sender, serverSenderName)
                }
                if event.isOwn || event.isEditable {
                    Divider()
                    if event.isEditable, let body = rawBody {
                        Button("Edit") { onEdit(eid, body) }
                    }
                    Button("Redact", role: .destructive) { onRedact(eid) }
                }
            } else {
                Button("View Source", action: onShowSource)
                Button("Set Nickname for \(serverSenderName)…") {
                    onEditNickname(event.sender, serverSenderName)
                }
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
                .padding(isOwn ? .leading : .trailing, 8)
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private func hoverActions(eid: String) -> some View {
        HStack(spacing: 4) {
            ForEach(reactionHistory.top3, id: \.self) { emoji in
                Button {
                    reactionHistory.record(emoji)
                    onQuickReact(eid, emoji)
                } label: { Text(emoji).font(.system(size: 13)) }
                .buttonStyle(.plain).help("React \(emoji)")
            }
            Button { onReact(eid) } label: { Image(systemName: "face.smiling") }
                .buttonStyle(.plain).help("More reactions…")
            if event.canBeRepliedTo {
                Button { onReply(eid) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .buttonStyle(.plain).help("Reply")
            }
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
                    if event.isEditable, let body = rawBody {
                        Button("Edit") { onEdit(eid, body) }
                    }
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
            if isEmojiOnlyMessage(t.body) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(t.body.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 44))
                        .textSelection(.enabled)
                    if msg.isEdited {
                        Text("(edited)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: bubbleAlignment)
            } else {
                let (segments, count) = MarkdownRenderer.render(body: t.body, formatted: t.formatted, revealedSpoilers: revealedSpoilers)
                VStack(alignment: alignment, spacing: 4) {
                    renderSegments(
                        segments,
                        spoilerCount: count,
                        edited: msg.isEdited,
                        horizontal: alignment,
                        secondary: false
                    )
                    if let url = firstURL(in: segments) {
                        LinkPreview(url: url)
                            .frame(maxWidth: 350, minHeight: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        case .notice(let n):
            let (segments, count) = MarkdownRenderer.render(body: n.body, formatted: n.formatted, revealedSpoilers: revealedSpoilers)
            renderSegments(
                segments,
                spoilerCount: count,
                edited: msg.isEdited,
                horizontal: alignment,
                secondary: true
            )
        case .emote(let e):
            let (segments, _) = MarkdownRenderer.render(body: e.body, formatted: e.formatted, revealedSpoilers: revealedSpoilers)
            let attr = MarkdownRenderer.flatten(segments)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                (Text("* \(senderName) ").italic() + Text(attr).italic())
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

    /// Render a list of `MarkdownRenderer.Segment`s — text runs get inline formatting
    /// + spoiler hit-testing via `renderableTextBody`; code blocks get their own bordered
    /// `CodeBlockView`. For single-text-segment messages we keep the old inline layout
    /// (edited indicator + spoiler eye sit on the last line); for mixed messages the
    /// edited/spoiler indicators move to a trailing row so they don't collide with the
    /// code block's chrome.
    @ViewBuilder
    private func renderSegments(_ segments: [MarkdownRenderer.Segment],
                                spoilerCount: Int,
                                edited: Bool,
                                horizontal: HorizontalAlignment,
                                secondary: Bool) -> some View {
        let bubbleAlignment: Alignment = (horizontal == .trailing) ? .trailing : .leading
        let hasCodeBlocks = segments.contains { if case .codeBlock = $0 { return true } else { return false } }
        if !hasCodeBlocks, segments.count == 1, case .text(let attr) = segments[0] {
            renderableTextBody(
                attributed: attr,
                spoilerCount: spoilerCount,
                edited: edited,
                alignment: bubbleAlignment,
                secondary: secondary
            )
        } else {
            VStack(alignment: horizontal, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let attr):
                        textOnlyBody(attr, alignment: bubbleAlignment, secondary: secondary)
                    case .codeBlock(let lang, let code):
                        CodeBlockView(language: lang, code: code)
                    }
                }
                if edited || (spoilerCount > 0 && revealedSpoilers.count < spoilerCount) {
                    HStack(spacing: 6) {
                        if edited {
                            Text("(edited)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if spoilerCount > 0 && revealedSpoilers.count < spoilerCount {
                            Image(systemName: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Tap a hidden block to reveal it")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: bubbleAlignment)
                }
            }
        }
    }

    /// A text segment with spoiler tap-to-reveal but no trailing indicators — used when
    /// the segment is one of many in a mixed message.
    @ViewBuilder
    private func textOnlyBody(_ attr: AttributedString, alignment: Alignment, secondary: Bool) -> some View {
        let textView = Text(attr)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.blue)
        let styled: AnyView = secondary
            ? AnyView(textView.foregroundStyle(.secondary))
            : AnyView(textView)
        styled
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "spoiler",
                   let idx = Int(url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                    if revealedSpoilers.contains(idx) {
                        revealedSpoilers.remove(idx)
                    } else {
                        revealedSpoilers.insert(idx)
                    }
                    return .handled
                }
                return .systemAction
            })
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// First URL across all text segments. Used to pick which LinkPreview to surface
    /// below the bubble.
    private func firstURL(in segments: [MarkdownRenderer.Segment]) -> URL? {
        for segment in segments {
            if case .text(let attr) = segment, let url = attr.firstURL() {
                return url
            }
        }
        return nil
    }

    /// Text body that supports per-spoiler tap-to-reveal. We render via Text + AttributedString
    /// (so inline HTML formatting survives) and intercept tap on `spoiler://N` links via
    /// the OpenURLAction environment.
    @ViewBuilder
    private func renderableTextBody(attributed: AttributedString, spoilerCount: Int, edited: Bool, alignment: Alignment, secondary: Bool = false) -> some View {
        let textView = Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.blue)
        let styled: AnyView = secondary
            ? AnyView(textView.foregroundStyle(.secondary))
            : AnyView(textView)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            styled
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "spoiler",
                       let idx = Int(url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                        if revealedSpoilers.contains(idx) {
                            revealedSpoilers.remove(idx)
                        } else {
                            revealedSpoilers.insert(idx)
                        }
                        return .handled
                    }
                    return .systemAction
                })
            if edited {
                Text("(edited)").font(.caption2).foregroundStyle(.secondary)
            }
            if spoilerCount > 0 && revealedSpoilers.count < spoilerCount {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Tap a hidden block to reveal it")
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

    /// Compact time-only line shown for continuation messages in a group.
    /// Only visible on hover to keep grouped messages clean.
    @ViewBuilder
    private var continuationTimeLine: some View {
        HStack(spacing: 4) {
            Text(timeFull(date))
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .opacity(hovering ? 1 : 0)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if let status = event.localSendState, !isSent(status) {
                Text(sendStateLabel(status)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: hovering ? nil : 0)
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

    // MARK: - Reply preview

    @ViewBuilder
    private func replyPreview(_ details: InReplyToDetails?, alignment: HorizontalAlignment) -> some View {
        if let details {
            let ev = details.event()
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(replySenderName(ev))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(senderColor(for: replySenderId(ev)))
                    Text(replyBodyPreview(ev))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        }
    }

    private func replySenderName(_ ev: EmbeddedEventDetails) -> String {
        switch ev {
        case .ready(_, let sender, let profile, _, _):
            // Use local nickname if set, otherwise server display name
            let serverName: String?
            if case .ready(let name, _, _) = profile { serverName = name } else { serverName = nil }
            return nicknames.displayName(for: sender, fallback: serverName)
        default: return "Unknown"
        }
    }

    private func replySenderId(_ ev: EmbeddedEventDetails) -> String {
        switch ev {
        case .ready(_, let sender, _, _, _): return sender
        default: return ""
        }
    }

    private func replyBodyPreview(_ ev: EmbeddedEventDetails) -> String {
        switch ev {
        case .ready(let content, _, _, _, _):
            switch content {
            case .msgLike(let msg):
                switch msg.kind {
                case .message(let m):
                    switch m.msgType {
                    case .text(let t): return t.body
                    case .notice(let n): return n.body
                    case .emote(let e): return e.body
                    case .image: return "🖼 Image"
                    case .video: return "🎥 Video"
                    case .audio: return "🎵 Audio"
                    case .file: return "📄 File"
                    default: return "Message"
                    }
                case .redacted: return "(deleted)"
                case .unableToDecrypt: return "🔒 Encrypted"
                default: return "Event"
                }
            default: return "Event"
            }
        case .pending: return "Loading…"
        case .unavailable: return "Message unavailable"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Read receipts

    @ViewBuilder
    private func readReceiptsRow(alignment: HorizontalAlignment) -> some View {
        let receipts = event.readReceipts
            .filter { $0.key != session.currentUserId }
        if !receipts.isEmpty {
            HStack(spacing: -4) {
                if alignment == .trailing { Spacer() }
                ForEach(Array(receipts.keys.sorted().prefix(5)), id: \.self) { userId in
                    let member = room.members[userId]
                    let name = member?.displayName ?? String(userId.prefix(8))
                    let avatar = member?.avatarUrl
                    Avatar(name: name, mxc: avatar, size: 14)
                        .overlay(
                            Circle().stroke(Color(.windowBackgroundColor), lineWidth: 1)
                        )
                }
                if receipts.count > 5 {
                    Text("+\(receipts.count - 5)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                if alignment == .leading { Spacer() }
            }
            .padding(.top, 1)
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
        case .sendingFailed(let error, let isRecoverable):
            let detail: String
            switch error {
            case .insecureDevices(let map):
                detail = "insecure devices: \(map)"
            case .identityViolations(let users):
                detail = "identity violations: \(users)"
            case .crossVerificationRequired:
                detail = "cross-verification required"
            case .missingMediaContent:
                detail = "missing media"
            case .invalidMimeType(let m):
                detail = "bad mime: \(m)"
            case .genericApiError(let msg):
                detail = msg
            }
            return "failed: \(detail)"
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
                let sdkPath = try handle.path()
                let sdkUrl = URL(fileURLWithPath: sdkPath)
                
                // The SDK's MediaFile handle deletes the file when deallocated.
                // Copy it to our own temp directory so it survives long enough
                // for macOS Preview/QuickLook to open it.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let destUrl = tmp.appendingPathComponent(filename)
                
                if FileManager.default.fileExists(atPath: destUrl.path) {
                    try FileManager.default.removeItem(at: destUrl)
                }
                try FileManager.default.copyItem(at: sdkUrl, to: destUrl)
                
                await MainActor.run {
                    NSWorkspace.shared.open(destUrl)
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

import LinkPresentation

struct LinkPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        LPMetadataProvider().startFetchingMetadata(for: url) { metadata, error in
            if let metadata = metadata {
                DispatchQueue.main.async {
                    view.metadata = metadata
                    // Re-layout container
                    view.needsLayout = true
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: LPLinkView, context: Context) {}
}

private extension Character {
    /// True for pictographic emoji (excludes plain ASCII digits/`#`/`*` which are
    /// technically `isEmoji` but only become emoji with a keycap sequence).
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first else { return false }
        if unicodeScalars.count > 1 {
            return unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji }
        }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && first.value > 0x238C)
    }
}

/// A message whose visible content is only emoji (and whitespace) — rendered large,
/// jumbo-style, like other chat clients. Capped so a wall of emoji stays sane.
private func isEmojiOnlyMessage(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var count = 0
    for ch in trimmed where !ch.isWhitespace {
        guard ch.isEmojiGlyph else { return false }
        count += 1
        if count > 24 { return false }
    }
    return count > 0
}

extension AttributedString {
    func firstURL() -> URL? {
        for run in self.runs {
            if let url = run.link, url.scheme != "spoiler" {
                return url
            }
        }
        return nil
    }
}
