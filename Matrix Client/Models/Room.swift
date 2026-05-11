import Foundation
import Combine

/// A Matrix room — derived state we render directly, plus a timeline of events and
/// a state map (`type` + `stateKey` → event).
@MainActor
final class Room: ObservableObject, Identifiable {
    let id: String
    @Published var name: String?
    @Published var topic: String?
    @Published var avatarMxc: String?
    @Published var isEncrypted: Bool = false
    @Published var isDirect: Bool = false
    @Published var membership: Membership = .join
    @Published var unreadCount: Int = 0
    @Published var highlightCount: Int = 0
    @Published var heroes: [String] = []      // user IDs from summary, used for DM names
    @Published var joinedMemberCount: Int = 0
    @Published var invitedMemberCount: Int = 0
    @Published var timeline: [MatrixEvent] = []
    @Published var stateByKey: [StateKey: MatrixEvent] = [:]
    @Published var members: [String: MatrixEvent] = [:]   // userId → m.room.member event
    @Published var reactionsByTarget: [String: [Reaction]] = [:] // targetEventId → reactions
    @Published var pinnedEventIds: [String] = []
    @Published var redactedEventIds: Set<String> = []
    @Published var prevBatch: String?
    @Published var typingUserIds: Set<String> = []
    @Published var paginating: Bool = false

    init(id: String) { self.id = id }

    struct StateKey: Hashable, Sendable {
        let type: String
        let stateKey: String
    }

    struct Reaction: Hashable, Sendable, Identifiable {
        let eventId: String   // reaction event id, used for redaction
        let key: String       // emoji
        let sender: String
        var id: String { eventId }
    }

    /// Sanitized display name. For DMs without a name, falls back to the other party's name.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if isDirect, let other = heroes.first {
            return memberDisplayName(other) ?? other
        }
        if !heroes.isEmpty {
            let names = heroes.prefix(3).map { memberDisplayName($0) ?? $0 }
            return names.joined(separator: ", ")
        }
        return id
    }

    func memberDisplayName(_ userId: String) -> String? {
        members[userId]?.content["displayname"]?.stringValue
    }

    func memberAvatar(_ userId: String) -> String? {
        members[userId]?.content["avatar_url"]?.stringValue
    }

    /// Power level for a user (defaults to users_default or 0).
    func powerLevel(of userId: String) -> Int {
        guard let pl = stateByKey[StateKey(type: "m.room.power_levels", stateKey: "")] else {
            return 0
        }
        if let override = pl.content["users"]?[userId]?.intValue { return Int(override) }
        if let def = pl.content["users_default"]?.intValue { return Int(def) }
        return 0
    }

    func powerLevelRequired(for action: String) -> Int {
        guard let pl = stateByKey[StateKey(type: "m.room.power_levels", stateKey: "")] else {
            return 50
        }
        if let v = pl.content[action]?.intValue { return Int(v) }
        return 50
    }

    /// Apply an incoming state event, updating derived fields where relevant.
    func applyState(_ event: MatrixEvent) {
        guard let sk = event.stateKey else { return }
        stateByKey[StateKey(type: event.type, stateKey: sk)] = event
        switch event.type {
        case "m.room.name":
            name = event.content["name"]?.stringValue
        case "m.room.topic":
            topic = event.content["topic"]?.stringValue
        case "m.room.avatar":
            avatarMxc = event.content["url"]?.stringValue
        case "m.room.encryption":
            isEncrypted = true
        case "m.room.member":
            members[sk] = event
        case "m.room.pinned_events":
            pinnedEventIds = event.content["pinned"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        default: break
        }
    }

    /// Apply an incoming timeline event. Reactions / redactions are folded into derived
    /// state so the UI doesn't have to filter them out itself.
    func applyTimeline(_ event: MatrixEvent) {
        switch event.type {
        case "m.reaction":
            if let target = event.reactionTargetEventId, let key = event.reactionKey {
                var list = reactionsByTarget[target] ?? []
                if !list.contains(where: { $0.eventId == event.eventId }) {
                    list.append(Reaction(eventId: event.eventId, key: key, sender: event.sender))
                    reactionsByTarget[target] = list
                }
            }
            timeline.append(event)
        case "m.room.redaction":
            if let target = event.content["redacts"]?.stringValue
                ?? event.raw["redacts"]?.stringValue {
                redactedEventIds.insert(target)
                // Remove reaction entries that point at the redacted event id.
                for (k, list) in reactionsByTarget {
                    let filtered = list.filter { $0.eventId != target }
                    if filtered.count != list.count { reactionsByTarget[k] = filtered }
                }
            }
            timeline.append(event)
        default:
            timeline.append(event)
            if event.isState { applyState(event) }
        }
    }
}
