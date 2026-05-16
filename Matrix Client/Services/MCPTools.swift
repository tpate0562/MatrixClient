import Foundation
import MatrixRustSDK

/// All MCP tools exposed by `MCPServer`. Each tool is a `name + inputSchema` entry in
/// `toolDefinitions` and a case in `execute`. Tools delegate to `MatrixSession` and
/// `RoomVM` on the main actor — no Matrix-SDK calls live here directly.
enum MCPTools {

    // MARK: - Tool catalog

    static let toolDefinitions: [[String: Any]] = [
        // Session
        tool("whoami",
             "Return the signed-in user's Matrix ID, device ID, and homeserver.",
             properties: [:]),
        tool("get_sync_state",
             "Return the current sliding-sync state (idle / running / terminated / error) and the recovery + verification status.",
             properties: [:]),
        tool("list_rooms",
             "List every joined room with display name, alias, member count, encryption, unread counters.",
             properties: [
                "filter": ["type": "string", "description": "Optional substring filter on the room display name (case-insensitive)."],
                "limit": ["type": "integer", "description": "Cap the result count (default 200)."],
             ]),
        tool("list_invites",
             "List rooms the user has been invited to but has not joined yet.",
             properties: [:]),
        tool("create_room",
             "Create a new room. Returns the new room_id.",
             properties: [
                "name": ["type": "string", "description": "Room name (optional)."],
                "topic": ["type": "string", "description": "Room topic (optional)."],
                "is_direct": ["type": "boolean", "description": "Create as a DM (default false)."],
                "encrypted": ["type": "boolean", "description": "Enable E2EE (default true)."],
                "invite": ["type": "array", "items": ["type": "string"], "description": "Matrix user IDs to invite immediately."],
             ]),
        tool("join_room",
             "Join a room by room_id (!abc:server) or canonical alias (#name:server).",
             properties: [
                "identifier": ["type": "string", "description": "Room ID or canonical alias."],
             ],
             required: ["identifier"]),
        tool("accept_invite",
             "Accept a pending invite.",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),
        tool("reject_invite",
             "Reject a pending invite.",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),

        // Room queries
        tool("get_room",
             "Detailed metadata for one room (topic, alias, member count, pinned events, recovery + encryption state, unread counts).",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),
        tool("list_messages",
             "Recent timeline messages from a room, oldest → newest. Opens the timeline if it isn't already attached, then snapshots the current items.",
             properties: [
                "room_id": roomIdSchema,
                "limit": ["type": "integer", "description": "Max messages to return (default 50, cap 200)."],
                "include_events": ["type": "boolean", "description": "Include non-message events (joins, edits, redactions). Default false — only m.room.message."],
             ],
             required: ["room_id"]),
        tool("search_messages",
             "Substring search across the current loaded timeline of a room.",
             properties: [
                "room_id": roomIdSchema,
                "query": ["type": "string", "description": "Case-insensitive substring."],
                "limit": ["type": "integer", "description": "Max matches (default 50)."],
             ],
             required: ["room_id", "query"]),
        tool("get_members",
             "List joined members of a room with display name, MXID, and power level.",
             properties: [
                "room_id": roomIdSchema,
                "limit": ["type": "integer", "description": "Cap (default 500)."],
             ],
             required: ["room_id"]),
        tool("list_pinned",
             "Event IDs currently pinned in the room.",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),

        // Room writes
        tool("send_message",
             "Send a text message. `body` may contain Markdown; it is converted to HTML for clients that render formatted bodies. Discord-style `||spoiler||` and the leading `/rainbow ...` / `/spoiler ...` slash commands are supported.",
             properties: [
                "room_id": roomIdSchema,
                "body": ["type": "string", "description": "Message body (Markdown allowed)."],
             ],
             required: ["room_id", "body"]),
        tool("send_reply",
             "Reply to a specific event with a new message.",
             properties: [
                "room_id": roomIdSchema,
                "event_id": eventIdSchema,
                "body": ["type": "string", "description": "Reply body (Markdown allowed)."],
             ],
             required: ["room_id", "event_id", "body"]),
        tool("send_edit",
             "Edit one of your own messages (m.replace).",
             properties: [
                "room_id": roomIdSchema,
                "event_id": eventIdSchema,
                "body": ["type": "string", "description": "Replacement body (Markdown allowed)."],
             ],
             required: ["room_id", "event_id", "body"]),
        tool("redact_message",
             "Redact (delete) an event. Subject to your power level.",
             properties: [
                "room_id": roomIdSchema,
                "event_id": eventIdSchema,
                "reason": ["type": "string", "description": "Optional reason."],
             ],
             required: ["room_id", "event_id"]),
        tool("toggle_reaction",
             "Toggle an emoji reaction on an event (add if missing, remove if present).",
             properties: [
                "room_id": roomIdSchema,
                "event_id": eventIdSchema,
                "key": ["type": "string", "description": "Emoji or reaction key, e.g. '👍'."],
             ],
             required: ["room_id", "event_id", "key"]),
        tool("pin_event",
             "Pin an event in the room.",
             properties: ["room_id": roomIdSchema, "event_id": eventIdSchema],
             required: ["room_id", "event_id"]),
        tool("unpin_event",
             "Remove an event from the pinned list.",
             properties: ["room_id": roomIdSchema, "event_id": eventIdSchema],
             required: ["room_id", "event_id"]),
        tool("mark_as_read",
             "Mark the room read at its latest known event.",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),
        tool("set_typing",
             "Send a typing notification.",
             properties: [
                "room_id": roomIdSchema,
                "typing": ["type": "boolean", "description": "true to start, false to stop."],
             ],
             required: ["room_id", "typing"]),
        tool("paginate_history",
             "Paginate backwards from the oldest currently loaded event. Use this to fill in older history before calling `list_messages`.",
             properties: [
                "room_id": roomIdSchema,
                "pages": ["type": "integer", "description": "Number of /messages pages to fetch (default 1, cap 20)."],
             ],
             required: ["room_id"]),
        tool("leave_room",
             "Leave the room. Use with caution — irreversible without re-invite for private rooms.",
             properties: ["room_id": roomIdSchema],
             required: ["room_id"]),

        // Admin
        tool("set_room_name",
             "Update the room name (state event m.room.name).",
             properties: [
                "room_id": roomIdSchema,
                "name": ["type": "string"],
             ],
             required: ["room_id", "name"]),
        tool("set_room_topic",
             "Update the room topic (state event m.room.topic).",
             properties: [
                "room_id": roomIdSchema,
                "topic": ["type": "string"],
             ],
             required: ["room_id", "topic"]),
        tool("invite_user",
             "Invite a user to the room.",
             properties: [
                "room_id": roomIdSchema,
                "user_id": userIdSchema,
             ],
             required: ["room_id", "user_id"]),
        tool("kick_user",
             "Kick a user from the room.",
             properties: [
                "room_id": roomIdSchema,
                "user_id": userIdSchema,
                "reason": ["type": "string", "description": "Optional reason shown to the kicked user."],
             ],
             required: ["room_id", "user_id"]),
        tool("ban_user",
             "Ban a user from the room.",
             properties: [
                "room_id": roomIdSchema,
                "user_id": userIdSchema,
                "reason": ["type": "string", "description": "Optional reason."],
             ],
             required: ["room_id", "user_id"]),
        tool("unban_user",
             "Lift a ban so the user can rejoin (or be re-invited).",
             properties: [
                "room_id": roomIdSchema,
                "user_id": userIdSchema,
             ],
             required: ["room_id", "user_id"]),
        tool("set_power_level",
             "Change a user's power level in the room (0 = default, 50 = moderator, 100 = admin).",
             properties: [
                "room_id": roomIdSchema,
                "user_id": userIdSchema,
                "level": ["type": "integer", "description": "New power level."],
             ],
             required: ["room_id", "user_id", "level"]),
    ]

    private static let roomIdSchema: [String: Any] = [
        "type": "string",
        "description": "Full Matrix room ID, e.g. !abcdef:matrix.org. Use list_rooms first to enumerate them.",
    ]
    private static let userIdSchema: [String: Any] = [
        "type": "string",
        "description": "Full Matrix user ID, e.g. @alice:matrix.org.",
    ]
    private static let eventIdSchema: [String: Any] = [
        "type": "string",
        "description": "Event ID like $abc123…, returned by list_messages.",
    ]

    private static func tool(_ name: String, _ description: String,
                             properties: [String: [String: Any]],
                             required: [String] = []) -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }

    // MARK: - Dispatch

    @MainActor
    static func execute(name: String, arguments: [String: Any], session: MatrixSession) async throws -> [String: Any] {
        switch name {

        // ---- session-level ----
        case "whoami":
            let s = session.session
            return textResult("user_id: \(s?.userId ?? "n/a")\ndevice_id: \(s?.deviceId ?? "n/a")\nhomeserver: \(s?.homeserverUrl ?? "n/a")",
                              structured: [
                                "user_id": s?.userId ?? NSNull(),
                                "device_id": s?.deviceId ?? NSNull(),
                                "homeserver": s?.homeserverUrl ?? NSNull(),
                              ])

        case "get_sync_state":
            return textResult(
                "sync_state: \(describeSyncState(session.syncState))\nrecovery: \(describeRecovery(session.recoveryState))\nverification: \(describeVerification(session.verificationState))",
                structured: [
                    "sync_state": describeSyncState(session.syncState),
                    "recovery": describeRecovery(session.recoveryState),
                    "verification": describeVerification(session.verificationState),
                ])

        case "list_rooms":
            let filter = (arguments["filter"] as? String)?.lowercased()
            let limit = clampInt(arguments["limit"], default: 200, max: 1000)
            let summaries = session.roomOrder.compactMap { session.rooms[$0] }
                .filter { vm in
                    guard let f = filter, !f.isEmpty else { return true }
                    return vm.displayName.lowercased().contains(f)
                }
                .prefix(limit)
                .map { vm -> [String: Any] in
                    return [
                        "room_id": vm.id,
                        "name": vm.displayName,
                        "alias": vm.canonicalAlias ?? NSNull(),
                        "topic": vm.topic ?? NSNull(),
                        "is_direct": vm.isDirect,
                        "is_encrypted": vm.isEncrypted,
                        "members": vm.joinedMembersCount,
                        "unread_notifications": vm.unreadNotifications,
                        "unread_highlights": vm.unreadHighlights,
                    ]
                }
            let summary = "\(summaries.count) rooms"
            return textResult(summary, structured: ["rooms": summaries])

        case "list_invites":
            let invites = session.invites.values.map { vm -> [String: Any] in
                return [
                    "room_id": vm.id,
                    "name": vm.displayName,
                    "alias": vm.canonicalAlias ?? NSNull(),
                    "topic": vm.topic ?? NSNull(),
                ]
            }
            return textResult("\(invites.count) pending invites", structured: ["invites": invites])

        case "create_room":
            let name = arguments["name"] as? String
            let topic = arguments["topic"] as? String
            let isDirect = arguments["is_direct"] as? Bool ?? false
            let encrypted = arguments["encrypted"] as? Bool ?? true
            let invite = arguments["invite"] as? [String] ?? []
            guard let id = await session.createRoom(name: name, topic: topic, isDirect: isDirect, invite: invite, encrypted: encrypted) else {
                throw MCPToolError(session.lastError ?? "createRoom returned nil")
            }
            return textResult("Created room \(id)", structured: ["room_id": id])

        case "join_room":
            let identifier = try requireString(arguments, "identifier")
            await session.joinByAliasOrId(identifier)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Joined \(identifier)")

        case "accept_invite":
            let roomId = try requireString(arguments, "room_id")
            await session.acceptInvite(roomId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Accepted invite to \(roomId)")

        case "reject_invite":
            let roomId = try requireString(arguments, "room_id")
            await session.rejectInvite(roomId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Rejected invite to \(roomId)")

        // ---- room queries ----
        case "get_room":
            let vm = try requireRoom(arguments, session: session)
            await vm.openTimeline()
            await vm.loadMembers()
            let result: [String: Any] = [
                "room_id": vm.id,
                "name": vm.displayName,
                "alias": vm.canonicalAlias ?? NSNull(),
                "topic": vm.topic ?? NSNull(),
                "is_direct": vm.isDirect,
                "is_encrypted": vm.isEncrypted,
                "members": vm.joinedMembersCount,
                "members_loaded": vm.membersLoaded,
                "pinned_event_ids": vm.pinnedEventIds,
                "unread_notifications": vm.unreadNotifications,
                "unread_highlights": vm.unreadHighlights,
                "membership": describeMembership(vm.membership),
                "my_power_level": vm.myPowerLevel,
                "can_paginate": vm.canPaginate,
                "loaded_items": vm.items.count,
            ]
            return textResult(humanRoomSummary(result), structured: result)

        case "list_messages":
            let vm = try requireRoom(arguments, session: session)
            let limit = clampInt(arguments["limit"], default: 50, max: 200)
            let includeEvents = arguments["include_events"] as? Bool ?? false
            await vm.openTimeline()
            let messages = messageSnapshots(from: vm, limit: limit, includeEvents: includeEvents)
            let header = "Showing \(messages.count) of \(vm.items.count) loaded events"
            return textResult(header + "\n\n" + renderMessages(messages),
                              structured: ["messages": messages])

        case "search_messages":
            let vm = try requireRoom(arguments, session: session)
            let query = try requireString(arguments, "query").lowercased()
            let limit = clampInt(arguments["limit"], default: 50, max: 200)
            await vm.openTimeline()
            let all = messageSnapshots(from: vm, limit: 10_000, includeEvents: false)
            let matches = all.filter { ($0["body"] as? String)?.lowercased().contains(query) ?? false }
                .suffix(limit)
            let matchArr = Array(matches)
            return textResult("\(matchArr.count) matches for \"\(query)\"\n\n" + renderMessages(matchArr),
                              structured: ["matches": matchArr])

        case "get_members":
            let vm = try requireRoom(arguments, session: session)
            let limit = clampInt(arguments["limit"], default: 500, max: 5000)
            await vm.loadMembers()
            let members = vm.members.values
                .map { m -> [String: Any] in
                    return [
                        "user_id": m.userId,
                        "display_name": m.displayName ?? NSNull(),
                        "avatar": m.avatarUrl ?? NSNull(),
                        "power_level": vm.powerLevel(of: m.userId),
                        "membership": describeMembershipState(m.membership),
                    ]
                }
                .sorted {
                    let aLevel = ($0["power_level"] as? Int) ?? 0
                    let bLevel = ($1["power_level"] as? Int) ?? 0
                    if aLevel != bLevel { return aLevel > bLevel }
                    return (($0["user_id"] as? String) ?? "") < (($1["user_id"] as? String) ?? "")
                }
                .prefix(limit)
            return textResult("\(members.count) members",
                              structured: ["members": Array(members)])

        case "list_pinned":
            let vm = try requireRoom(arguments, session: session)
            return textResult("\(vm.pinnedEventIds.count) pinned events",
                              structured: ["pinned_event_ids": vm.pinnedEventIds])

        // ---- room writes ----
        case "send_message":
            let vm = try requireRoom(arguments, session: session)
            let body = try requireString(arguments, "body")
            await vm.openTimeline()
            await vm.send(body)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Sent message to \(vm.displayName)")

        case "send_reply":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            let body = try requireString(arguments, "body")
            await vm.openTimeline()
            await vm.sendReply(to: eventId, text: body)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Replied to \(eventId.prefix(16))…")

        case "send_edit":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            let body = try requireString(arguments, "body")
            await vm.openTimeline()
            await vm.sendEdit(to: eventId, text: body)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Edited \(eventId.prefix(16))…")

        case "redact_message":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            await vm.openTimeline()
            await vm.redact(eventId: eventId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Redacted \(eventId.prefix(16))…")

        case "toggle_reaction":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            let key = try requireString(arguments, "key")
            await vm.openTimeline()
            await vm.toggleReaction(targetEventId: eventId, key: key)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Toggled \(key) on \(eventId.prefix(16))…")

        case "pin_event":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            await vm.openTimeline()
            await vm.pin(eventId: eventId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Pinned \(eventId.prefix(16))…")

        case "unpin_event":
            let vm = try requireRoom(arguments, session: session)
            let eventId = try requireString(arguments, "event_id")
            await vm.openTimeline()
            await vm.unpin(eventId: eventId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Unpinned \(eventId.prefix(16))…")

        case "mark_as_read":
            let vm = try requireRoom(arguments, session: session)
            await vm.openTimeline()
            await vm.markAsRead()
            return textResult("Marked \(vm.displayName) as read")

        case "set_typing":
            let vm = try requireRoom(arguments, session: session)
            let typing = arguments["typing"] as? Bool ?? false
            await vm.setTyping(typing)
            return textResult(typing ? "Typing…" : "Stopped typing")

        case "paginate_history":
            let vm = try requireRoom(arguments, session: session)
            let pages = clampInt(arguments["pages"], default: 1, max: 20)
            await vm.openTimeline()
            for _ in 0..<pages {
                await vm.paginate()
                if !vm.canPaginate { break }
            }
            return textResult("Loaded history (\(vm.items.count) total items, can_paginate=\(vm.canPaginate))")

        case "leave_room":
            let vm = try requireRoom(arguments, session: session)
            await vm.leave()
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Left \(vm.displayName)")

        // ---- admin ----
        case "set_room_name":
            let vm = try requireRoom(arguments, session: session)
            let name = try requireString(arguments, "name")
            await vm.setName(name)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Renamed room to '\(name)'")

        case "set_room_topic":
            let vm = try requireRoom(arguments, session: session)
            let topic = try requireString(arguments, "topic")
            await vm.setTopic(topic)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Updated topic")

        case "invite_user":
            let vm = try requireRoom(arguments, session: session)
            let userId = try requireString(arguments, "user_id")
            await vm.invite(userId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Invited \(userId)")

        case "kick_user":
            let vm = try requireRoom(arguments, session: session)
            let userId = try requireString(arguments, "user_id")
            let reason = arguments["reason"] as? String
            await vm.kick(userId, reason: reason)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Kicked \(userId)")

        case "ban_user":
            let vm = try requireRoom(arguments, session: session)
            let userId = try requireString(arguments, "user_id")
            let reason = arguments["reason"] as? String
            await vm.ban(userId, reason: reason)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Banned \(userId)")

        case "unban_user":
            let vm = try requireRoom(arguments, session: session)
            let userId = try requireString(arguments, "user_id")
            await vm.unban(userId)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Unbanned \(userId)")

        case "set_power_level":
            let vm = try requireRoom(arguments, session: session)
            let userId = try requireString(arguments, "user_id")
            let level = try requireInt(arguments, "level")
            await vm.setPower(userId, level: level)
            if let err = session.lastError { throw MCPToolError(err) }
            return textResult("Set \(userId) power level to \(level)")

        default:
            throw MCPToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Result helpers

    static func textResult(_ text: String, structured: [String: Any]? = nil) -> [String: Any] {
        var out: [String: Any] = ["content": [["type": "text", "text": text]]]
        if let structured = structured { out["structuredContent"] = structured }
        return out
    }

    static func errorContent(_ message: String) -> [String: Any] {
        return [
            "content": [["type": "text", "text": "Error: \(message)"]],
            "isError": true,
        ]
    }

    // MARK: - Argument helpers

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw MCPToolError("Missing required argument: \(key)")
        }
        return value
    }

    private static func requireInt(_ args: [String: Any], _ key: String) throws -> Int {
        if let n = args[key] as? Int { return n }
        if let n = args[key] as? NSNumber { return n.intValue }
        if let s = args[key] as? String, let n = Int(s) { return n }
        throw MCPToolError("Missing required integer: \(key)")
    }

    private static func clampInt(_ value: Any?, default def: Int, max: Int) -> Int {
        let n: Int
        if let v = value as? Int { n = v }
        else if let v = value as? NSNumber { n = v.intValue }
        else { n = def }
        return Swift.max(1, Swift.min(n, max))
    }

    @MainActor
    private static func requireRoom(_ args: [String: Any], session: MatrixSession) throws -> RoomVM {
        let id = try requireString(args, "room_id")
        if let vm = session.rooms[id] { return vm }
        if let vm = session.invites[id] { return vm }
        throw MCPToolError("Unknown room_id: \(id) — call list_rooms first")
    }

    // MARK: - Snapshot helpers

    @MainActor
    private static func messageSnapshots(from vm: RoomVM, limit: Int, includeEvents: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let items = vm.items
        for item in items.reversed() {
            if out.count >= limit { break }
            if let snap = snapshot(item: item, members: vm.members, includeEvents: includeEvents) {
                out.append(snap)
            }
        }
        return out.reversed()
    }

    @MainActor
    private static func snapshot(item: TimelineItem, members: [String: RoomMember], includeEvents: Bool) -> [String: Any]? {
        guard let event = item.asEvent() else { return nil }
        var eventId: String? = nil
        if case .eventId(let id) = event.eventOrTransactionId { eventId = id }

        let sender = event.sender
        let senderName: String? = {
            if case .ready(let name, _, _) = event.senderProfile { return name }
            return members[sender]?.displayName
        }()
        let timestamp = Int64(event.timestamp)
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)

        var base: [String: Any] = [
            "event_id": eventId ?? NSNull(),
            "sender": sender,
            "sender_name": senderName ?? NSNull(),
            "timestamp_ms": timestamp,
            "iso_time": iso8601(date),
        ]

        switch event.content {
        case .msgLike(let content):
            if case .message(let msg) = content.kind {
                let (body, html, kind) = extractMessage(msg.msgType)
                base["type"] = "m.room.message"
                base["msgtype"] = kind
                base["body"] = body.isEmpty ? msg.body : body
                if let html = html { base["formatted_body"] = html }
                return base
            }
            if !includeEvents { return nil }
            base["type"] = "m.msglike.\(describeMsgLike(content.kind))"
            return base
        default:
            if !includeEvents { return nil }
            base["type"] = "non_message_event"
            return base
        }
    }

    private static func extractMessage(_ type: MessageType) -> (String, String?, String) {
        switch type {
        case .text(let t):     return (t.body, t.formatted?.body, "m.text")
        case .notice(let n):   return (n.body, n.formatted?.body, "m.notice")
        case .emote(let e):    return (e.body, nil, "m.emote")
        case .image(let i):    return (i.caption ?? i.filename, i.formattedCaption?.body, "m.image")
        case .video(let v):    return (v.caption ?? v.filename, v.formattedCaption?.body, "m.video")
        case .audio(let a):    return (a.caption ?? a.filename, a.formattedCaption?.body, "m.audio")
        case .file(let f):     return (f.caption ?? f.filename, f.formattedCaption?.body, "m.file")
        case .gallery(let g):  return (g.body, g.formatted?.body, "m.gallery")
        case .location(let l): return (l.body, nil, "m.location")
        case .other(let t, let b): return (b, nil, t)
        }
    }

    private static func describeMsgLike(_ kind: MsgLikeKind) -> String {
        switch kind {
        case .message:         return "message"
        case .redacted:        return "redacted"
        case .sticker:         return "sticker"
        case .unableToDecrypt: return "utd"
        case .poll:            return "poll"
        case .liveLocation:    return "live_location"
        case .other:           return "other"
        }
    }

    private static func describeMembership(_ m: Membership) -> String {
        switch m {
        case .joined:  return "joined"
        case .invited: return "invited"
        case .left:    return "left"
        case .knocked: return "knocked"
        case .banned:  return "banned"
        }
    }

    private static func describeMembershipState(_ m: MembershipState) -> String {
        switch m {
        case .ban:    return "ban"
        case .invite: return "invite"
        case .join:   return "join"
        case .knock:  return "knock"
        case .leave:  return "leave"
        case .custom(let v): return "custom(\(v))"
        }
    }

    private static func describeSyncState(_ s: SyncServiceState) -> String {
        switch s {
        case .idle:       return "idle"
        case .running:    return "running"
        case .terminated: return "terminated"
        case .error:      return "error"
        case .offline:    return "offline"
        }
    }

    private static func describeRecovery(_ r: RecoveryState) -> String {
        switch r {
        case .unknown:    return "unknown"
        case .enabled:    return "enabled"
        case .disabled:   return "disabled"
        case .incomplete: return "incomplete"
        }
    }

    private static func describeVerification(_ v: VerificationState) -> String {
        switch v {
        case .unknown:    return "unknown"
        case .verified:   return "verified"
        case .unverified: return "unverified"
        }
    }

    // MARK: - Rendering

    private static func renderMessages(_ msgs: [[String: Any]]) -> String {
        return msgs.map { m -> String in
            let time = (m["iso_time"] as? String) ?? ""
            let sender = (m["sender_name"] as? String) ?? (m["sender"] as? String) ?? "?"
            let body = (m["body"] as? String) ?? ""
            let eid = (m["event_id"] as? String) ?? ""
            return "[\(time)] \(sender) (\(eid.prefix(16))…): \(body)"
        }.joined(separator: "\n")
    }

    private static func humanRoomSummary(_ r: [String: Any]) -> String {
        var lines: [String] = []
        if let n = r["name"] as? String { lines.append("Room: \(n)") }
        if let id = r["room_id"] as? String { lines.append("ID: \(id)") }
        if let a = r["alias"] as? String { lines.append("Alias: \(a)") }
        if let t = r["topic"] as? String { lines.append("Topic: \(t)") }
        lines.append("Members: \(r["members"] ?? 0)")
        lines.append("Encrypted: \(r["is_encrypted"] as? Bool == true)")
        lines.append("Unread: \(r["unread_notifications"] ?? 0) (highlights: \(r["unread_highlights"] ?? 0))")
        return lines.joined(separator: "\n")
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
