import Foundation

/// A Matrix timeline or state event. Stores the parsed top-level fields plus the full
/// content blob as JSON so we can render unknown event types and show "view source".
struct MatrixEvent: Identifiable, Hashable, Sendable {
    let eventId: String
    let roomId: String?
    let type: String
    let sender: String
    let content: JSONValue
    let stateKey: String?
    let originServerTs: Int64
    let unsigned: JSONValue?
    let raw: JSONValue

    var id: String { eventId }
    var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(originServerTs) / 1000.0) }

    var isState: Bool { stateKey != nil }
    var isRedacted: Bool { unsigned?["redacted_because"] != nil }

    // m.room.message helpers.
    var messageBody: String? { content["body"]?.stringValue }
    var msgType: String? { content["msgtype"]?.stringValue }
    var isEdit: Bool {
        content["m.relates_to"]?["rel_type"]?.stringValue == "m.replace"
    }
    var replacesEventId: String? {
        guard isEdit else { return nil }
        return content["m.relates_to"]?["event_id"]?.stringValue
    }
    var newContent: JSONValue? { content["m.new_content"] }
    var inReplyToEventId: String? {
        content["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.stringValue
    }

    // m.reaction helpers.
    var reactionTargetEventId: String? {
        guard type == "m.reaction" else { return nil }
        let rel = content["m.relates_to"]
        guard rel?["rel_type"]?.stringValue == "m.annotation" else { return nil }
        return rel?["event_id"]?.stringValue
    }
    var reactionKey: String? {
        guard type == "m.reaction" else { return nil }
        return content["m.relates_to"]?["key"]?.stringValue
    }

    static func decode(roomId: String?, value: JSONValue) -> MatrixEvent? {
        guard
            let type = value["type"]?.stringValue,
            let sender = value["sender"]?.stringValue,
            let ts = value["origin_server_ts"]?.intValue
        else { return nil }
        let eventId = value["event_id"]?.stringValue ?? UUID().uuidString
        let content = value["content"] ?? .object([:])
        let stateKey = value["state_key"]?.stringValue
        return MatrixEvent(
            eventId: eventId,
            roomId: roomId,
            type: type,
            sender: sender,
            content: content,
            stateKey: stateKey,
            originServerTs: ts,
            unsigned: value["unsigned"],
            raw: value
        )
    }
}

/// Membership states (per spec).
enum Membership: String, Sendable {
    case join, leave, invite, ban, knock
}
