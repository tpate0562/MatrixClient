import Foundation

/// Result of a /sync call. We parse the bits we need by hand from a JSONValue,
/// because the response uses dynamic room-id keys that don't map cleanly to Codable.
struct SyncResponse: Sendable {
    let nextBatch: String
    let join: [String: JoinedRoom]
    let invite: [String: InvitedRoom]
    let leave: [String: LeftRoom]
    let accountData: [MatrixEvent]
    let toDevice: [MatrixEvent]   // for future E2EE: m.room_key, m.room_key_request, etc.

    struct JoinedRoom: Sendable {
        let timeline: [MatrixEvent]
        let state: [MatrixEvent]
        let accountData: [MatrixEvent]
        let ephemeral: [MatrixEvent]
        let unreadCount: Int
        let highlightCount: Int
        let heroes: [String]
        let joinedMemberCount: Int
        let invitedMemberCount: Int
        let prevBatch: String?
        let limited: Bool
    }

    struct InvitedRoom: Sendable {
        let inviteState: [MatrixEvent]
    }

    struct LeftRoom: Sendable {
        let timeline: [MatrixEvent]
        let state: [MatrixEvent]
    }

    static func parse(_ json: JSONValue) -> SyncResponse? {
        guard let nextBatch = json["next_batch"]?.stringValue else { return nil }

        let joinRaw = json["rooms"]?["join"]?.objectValue ?? [:]
        var join: [String: JoinedRoom] = [:]
        for (roomId, val) in joinRaw {
            let timeline = (val["timeline"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            let state = (val["state"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            let accountData = (val["account_data"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            let ephemeral = (val["ephemeral"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            let summary = val["summary"]
            let heroes = summary?["m.heroes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let joinedCount = summary?["m.joined_member_count"]?.intValue.map(Int.init) ?? 0
            let invitedCount = summary?["m.invited_member_count"]?.intValue.map(Int.init) ?? 0
            let unread = val["unread_notifications"]?["notification_count"]?.intValue.map(Int.init) ?? 0
            let highlight = val["unread_notifications"]?["highlight_count"]?.intValue.map(Int.init) ?? 0
            let prevBatch = val["timeline"]?["prev_batch"]?.stringValue
            let limited = val["timeline"]?["limited"]?.boolValue ?? false
            join[roomId] = JoinedRoom(
                timeline: timeline, state: state, accountData: accountData,
                ephemeral: ephemeral,
                unreadCount: unread, highlightCount: highlight,
                heroes: heroes,
                joinedMemberCount: joinedCount, invitedMemberCount: invitedCount,
                prevBatch: prevBatch, limited: limited
            )
        }

        let inviteRaw = json["rooms"]?["invite"]?.objectValue ?? [:]
        var invite: [String: InvitedRoom] = [:]
        for (roomId, val) in inviteRaw {
            let events = (val["invite_state"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            invite[roomId] = InvitedRoom(inviteState: events)
        }

        let leaveRaw = json["rooms"]?["leave"]?.objectValue ?? [:]
        var leave: [String: LeftRoom] = [:]
        for (roomId, val) in leaveRaw {
            let timeline = (val["timeline"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            let state = (val["state"]?["events"]?.arrayValue ?? [])
                .compactMap { MatrixEvent.decode(roomId: roomId, value: $0) }
            leave[roomId] = LeftRoom(timeline: timeline, state: state)
        }

        let accountData = (json["account_data"]?["events"]?.arrayValue ?? [])
            .compactMap { MatrixEvent.decode(roomId: nil, value: $0) }
        let toDevice = (json["to_device"]?["events"]?.arrayValue ?? [])
            .compactMap { MatrixEvent.decode(roomId: nil, value: $0) }

        return SyncResponse(
            nextBatch: nextBatch,
            join: join, invite: invite, leave: leave,
            accountData: accountData,
            toDevice: toDevice
        )
    }
}
