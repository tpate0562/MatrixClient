import Foundation
import SwiftUI
import Combine

/// The app's top-level model: holds credentials, the room map, and drives /sync.
/// Owned by the App and injected into views via @EnvironmentObject.
@MainActor
final class MatrixSession: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var rooms: [String: Room] = [:]
    @Published private(set) var roomOrder: [String] = []        // most recent activity first
    @Published private(set) var invites: [String: Room] = [:]
    @Published private(set) var directRoomIds: Set<String> = []
    @Published private(set) var syncing: Bool = false
    @Published var lastError: String?

    let api: MatrixAPI
    private var syncTask: Task<Void, Never>?
    private var nextBatch: String?

    var currentUserId: String? { credentials?.userId }
    var isAuthenticated: Bool { credentials != nil }

    init() {
        self.api = MatrixAPI()
        if let creds = KeychainStore.load() {
            self.credentials = creds
            Task { await api.setHomeserver(creds.homeserverURL); await api.setToken(creds.accessToken) }
            // Kick off sync on next run-loop tick once api is configured.
            Task { await self.startSync() }
        }
    }

    // MARK: - Auth

    func login(homeserverInput: String, user: String, password: String) async {
        lastError = nil
        do {
            let resolved = try await api.discoverHomeserver(from: homeserverInput)
            let creds = try await api.login(homeserver: resolved, user: user, password: password)
            self.credentials = creds
            KeychainStore.save(creds)
            await startSync()
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func logout() async {
        syncTask?.cancel()
        syncTask = nil
        try? await api.logout()
        await api.setToken(nil)
        KeychainStore.clear()
        credentials = nil
        rooms = [:]
        invites = [:]
        roomOrder = []
        directRoomIds = []
        nextBatch = nil
    }

    // MARK: - Sync loop

    func startSync() async {
        guard syncTask == nil else { return }
        syncing = true
        syncTask = Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    private func runSyncLoop() async {
        // Initial sync — no timeout, fast turnaround.
        while !Task.isCancelled {
            do {
                let resp = try await api.sync(since: nextBatch, timeout: nextBatch == nil ? 0 : 30000)
                apply(resp)
                nextBatch = resp.nextBatch
            } catch {
                if Task.isCancelled { break }
                if case MatrixAPIError.http(let status, _, _) = error, status == 401 {
                    // Token revoked — log out cleanly.
                    await logout()
                    break
                }
                self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                // Backoff briefly before retrying.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        syncing = false
    }

    private func apply(_ resp: SyncResponse) {
        // Account data — figure out which rooms are DMs.
        for event in resp.accountData where event.type == "m.direct" {
            var ids = Set<String>()
            if let obj = event.content.objectValue {
                for (_, val) in obj {
                    for v in val.arrayValue ?? [] {
                        if let id = v.stringValue { ids.insert(id) }
                    }
                }
            }
            directRoomIds = ids
            for id in ids { rooms[id]?.isDirect = true }
        }

        // Joined rooms.
        var touched: [String] = []
        for (roomId, jr) in resp.join {
            let room = rooms[roomId] ?? {
                let r = Room(id: roomId)
                rooms[roomId] = r
                return r
            }()
            invites.removeValue(forKey: roomId)
            room.membership = .join
            room.isDirect = directRoomIds.contains(roomId) || room.isDirect
            room.unreadCount = jr.unreadCount
            room.highlightCount = jr.highlightCount
            if !jr.heroes.isEmpty { room.heroes = jr.heroes }
            if jr.joinedMemberCount > 0 { room.joinedMemberCount = jr.joinedMemberCount }
            if jr.invitedMemberCount > 0 { room.invitedMemberCount = jr.invitedMemberCount }
            if let pb = jr.prevBatch { room.prevBatch = pb }

            // State first, then timeline.
            for ev in jr.state { room.applyState(ev) }
            for ev in jr.timeline { room.applyTimeline(ev) }
            // Trim timeline to a sane size to keep memory bounded.
            if room.timeline.count > 500 {
                room.timeline = Array(room.timeline.suffix(500))
            }
            if !jr.timeline.isEmpty { touched.append(roomId) }
        }

        // Invites.
        for (roomId, ir) in resp.invite {
            let room = invites[roomId] ?? {
                let r = Room(id: roomId)
                invites[roomId] = r
                return r
            }()
            room.membership = .invite
            for ev in ir.inviteState { room.applyState(ev) }
        }

        // Leaves.
        for (roomId, _) in resp.leave {
            rooms.removeValue(forKey: roomId)
            invites.removeValue(forKey: roomId)
            roomOrder.removeAll { $0 == roomId }
        }

        // Rebuild room order — most recent activity first, then alphabetically.
        var order = rooms.keys.sorted { a, b in
            let ta = rooms[a]?.timeline.last?.originServerTs ?? 0
            let tb = rooms[b]?.timeline.last?.originServerTs ?? 0
            if ta != tb { return ta > tb }
            return (rooms[a]?.displayName ?? a) < (rooms[b]?.displayName ?? b)
        }
        // Promote touched rooms.
        for id in touched.reversed() where order.contains(id) {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
        }
        roomOrder = order
    }

    // MARK: - Convenience actions called from views

    func sendMessage(_ text: String, in roomId: String) async {
        guard !text.isEmpty else { return }
        do { _ = try await api.sendMessage(roomId: roomId, text: text) }
        catch { lastError = "\(error)" }
    }

    func toggleReaction(roomId: String, targetEventId: String, key: String) async {
        guard let me = currentUserId, let room = rooms[roomId] else { return }
        let existing = room.reactionsByTarget[targetEventId]?
            .first { $0.sender == me && $0.key == key }
        do {
            if let existing {
                _ = try await api.redact(roomId: roomId, eventId: existing.eventId)
            } else {
                _ = try await api.sendReaction(roomId: roomId, targetEventId: targetEventId, key: key)
            }
        } catch { lastError = "\(error)" }
    }

    func redact(roomId: String, eventId: String) async {
        do { _ = try await api.redact(roomId: roomId, eventId: eventId) }
        catch { lastError = "\(error)" }
    }

    func togglePin(roomId: String, eventId: String) async {
        guard let room = rooms[roomId] else { return }
        var pins = room.pinnedEventIds
        if let idx = pins.firstIndex(of: eventId) { pins.remove(at: idx) }
        else { pins.append(eventId) }
        do {
            _ = try await api.setState(
                roomId: roomId, type: "m.room.pinned_events", stateKey: "",
                content: ["pinned": pins]
            )
        } catch { lastError = "\(error)" }
    }

    func setRoomName(_ name: String, roomId: String) async {
        do {
            _ = try await api.setState(roomId: roomId, type: "m.room.name", content: ["name": name])
        } catch { lastError = "\(error)" }
    }

    func setRoomTopic(_ topic: String, roomId: String) async {
        do {
            _ = try await api.setState(roomId: roomId, type: "m.room.topic", content: ["topic": topic])
        } catch { lastError = "\(error)" }
    }

    func setPowerLevel(userId: String, level: Int, roomId: String) async {
        guard let room = rooms[roomId],
              let pl = room.stateByKey[Room.StateKey(type: "m.room.power_levels", stateKey: "")] else {
            lastError = "No power levels event in this room"
            return
        }
        var content = pl.content.objectValue ?? [:]
        var users = content["users"]?.objectValue ?? [:]
        users[userId] = .int(Int64(level))
        content["users"] = .object(users)
        do {
            let plain = jsonObject(content)
            _ = try await api.setState(roomId: roomId, type: "m.room.power_levels", content: plain)
        } catch { lastError = "\(error)" }
    }

    func leave(roomId: String) async {
        do {
            try await api.leaveRoom(roomId)
            rooms.removeValue(forKey: roomId)
            roomOrder.removeAll { $0 == roomId }
        } catch { lastError = "\(error)" }
    }

    func acceptInvite(_ roomId: String) async {
        do {
            _ = try await api.joinRoom(roomId)
            invites.removeValue(forKey: roomId)
        } catch { lastError = "\(error)" }
    }

    func rejectInvite(_ roomId: String) async {
        do {
            try await api.leaveRoom(roomId)
            invites.removeValue(forKey: roomId)
        } catch { lastError = "\(error)" }
    }

    func createRoom(name: String?, topic: String?, isDirect: Bool,
                    invite: [String], encrypted: Bool) async -> String? {
        do {
            let preset = isDirect ? "trusted_private_chat" : "private_chat"
            let id = try await api.createRoom(name: name, topic: topic, isDirect: isDirect,
                                              invite: invite, encrypted: encrypted, preset: preset)
            if isDirect, !invite.isEmpty {
                // Update m.direct account data so the other clients also mark it as a DM.
                let target = invite[0]
                var data: [String: [String]] = [:]
                data[target] = [id]
                _ = try? await api.setState(roomId: id, type: "m.direct", content: data)
            }
            return id
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    func joinByAlias(_ alias: String) async {
        do { _ = try await api.joinRoom(alias) }
        catch { lastError = "\(error)" }
    }

    func sendReadReceipt(roomId: String) async {
        guard let last = rooms[roomId]?.timeline.last else { return }
        try? await api.sendReadReceipt(roomId: roomId, eventId: last.eventId)
    }

    // MARK: - Helpers

    /// Convert a JSONValue dictionary back to a plain `[String: Any]` so it can be re-sent.
    private func jsonObject(_ obj: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in obj { out[k] = jsonAny(v) }
        return out
    }

    private func jsonAny(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { jsonAny($0) }
        case .object(let o): return jsonObject(o)
        }
    }
}
