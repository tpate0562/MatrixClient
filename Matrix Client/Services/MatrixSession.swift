import Foundation
import Combine
import MatrixRustSDK

/// The app-level model. Owns one SDK `Client` + its `SyncService` and surfaces an observable
/// room list. Per-room state (timeline, members, typing) lives in `RoomVM` instances.
@MainActor
final class MatrixSession: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var rooms: [String: RoomVM] = [:]
    @Published private(set) var roomOrder: [String] = []
    @Published private(set) var invites: [String: RoomVM] = [:]
    @Published private(set) var syncState: SyncServiceState = .idle
    @Published var lastError: String?
    @Published private(set) var recoveryState: RecoveryState = .unknown

    private(set) var client: Client?
    private var syncService: SyncService?
    private var roomListService: RoomListService?
    private var entriesResult: RoomListEntriesWithDynamicAdaptersResult?
    private var entriesStreamHandle: TaskHandle?
    private var syncStateHandle: TaskHandle?
    private var recoveryStateHandle: TaskHandle?
    private var verificationStateHandle: TaskHandle?
    private var listenerBox: RoomListListener?
    private var didPreloadTimelines = false
    @Published private(set) var verificationState: VerificationState = .unknown
    @Published private(set) var verification: VerificationController?

    var currentUserId: String? { session?.userId }
    var isAuthenticated: Bool { session != nil }

    init() {
        if let saved = KeychainStore.load() {
            Task { await self.restore(session: saved) }
        }
    }

    // MARK: - Lifecycle

    /// Build a Client for a homeserver (no session yet). Used as the first step of any flow.
    ///
    /// `freshStart=true` wipes the SDK's on-disk crypto + cache stores before building.
    /// Required for any path that creates a new device (password login, token login,
    /// OIDC) — the SDK refuses to attach a new device to a store that was previously
    /// bound to a different one (errors with "account in the store doesn't match the
    /// account in the constructor"). Restores keep the existing store.
    private func makeClient(homeserverUrlOrServerName input: String, freshStart: Bool = false) async throws -> Client {
        try await stop()
        let paths = try sessionPaths(wipe: freshStart)
        // Configuration mirrors what Element X iOS uses. The decryption / recipient
        // strategy lines are required for the SDK to actually publish device keys
        // and treat this device as E2EE-capable; without them other clients see this
        // session as "doesn't support encryption".
        let builder = ClientBuilder()
            .sessionPaths(dataPath: paths.data, cachePath: paths.cache)
            .userAgent(userAgent: "MatrixClient-macOS/1.0")
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            .enableShareHistoryOnInvite(enableShareHistoryOnInvite: true)
            .autoEnableBackups(autoEnableBackups: true)
            .roomKeyRecipientStrategy(strategy: .identityBasedStrategy)
            .decryptionSettings(decryptionSettings: DecryptionSettings(senderDeviceTrustRequirement: .untrusted))
            .setSessionDelegate(sessionDelegate: SessionDelegateBox())
            .serverNameOrHomeserverUrl(serverNameOrUrl: input.trimmingCharacters(in: .whitespaces))
        return try await builder.build()
    }

    /// Password login flow.
    func login(homeserverInput: String, user: String, password: String) async {
        lastError = nil
        do {
            let client = try await makeClient(homeserverUrlOrServerName: homeserverInput, freshStart: true)
            try await client.login(
                username: user, password: password,
                initialDeviceName: "Matrix Client (macOS)", deviceId: nil
            )
            let session = try client.session()
            try await activate(client: client, session: session)
        } catch {
            self.lastError = describe(error)
        }
    }

    /// Begin an OIDC (SSO) flow for the given homeserver. Returns the URL to open in a
    /// browser and the URL scheme our callback uses. The caller hosts an
    /// `ASWebAuthenticationSession`, then hands the captured callback URL back to
    /// `completeOIDC`. On cancel call `cancelOIDC`.
    private var oidcPendingClient: Client?
    private var oidcPendingAuthData: OAuthAuthorizationData?

    func beginOIDC(homeserverInput: String) async throws -> (loginURL: URL, callbackScheme: String) {
        lastError = nil
        // matrix-authentication-service enforces a Rego policy: the redirect URI's
        // private-use scheme must be a *reverse-DNS prefix* of the client_uri's host.
        // So `client_uri = https://github.com/...` forces a scheme that starts with
        // `com.github.…`. The URI also has to be in `scheme:/path` form (no authority).
        let clientUri = "https://github.com/tejaspatel/matrix-client"
        let scheme = "com.github.tejaspatel.matrix-client"
        let redirectUri = "\(scheme):/oauth-callback"
        let client = try await makeClient(homeserverUrlOrServerName: homeserverInput, freshStart: true)
        let details = await client.homeserverLoginDetails()
        guard details.supportsOidcLogin() else {
            throw SimpleError("This homeserver doesn't support OIDC sign-in. Try password or set one in your account settings.")
        }
        let config = OidcConfiguration(
            clientName: "Matrix Client (macOS)",
            redirectUri: redirectUri,
            clientUri: clientUri,
            logoUri: nil,
            tosUri: nil,
            policyUri: nil,
            staticRegistrations: [:]
        )
        let authData = try await client.urlForOidc(
            oidcConfiguration: config,
            prompt: nil,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )
        guard let url = URL(string: authData.loginUrl()) else {
            throw SimpleError("OIDC returned an invalid login URL")
        }
        self.oidcPendingClient = client
        self.oidcPendingAuthData = authData
        return (url, scheme)
    }

    /// Finish an OIDC flow with the callback URL returned by ASWebAuthenticationSession.
    func completeOIDC(callbackURL: URL) async {
        guard let client = oidcPendingClient else {
            self.lastError = "No OIDC flow in progress"
            return
        }
        do {
            try await client.loginWithOidcCallback(callbackUrl: callbackURL.absoluteString)
            try await activate(client: client, session: try client.session())
            self.oidcPendingClient = nil
            self.oidcPendingAuthData = nil
        } catch {
            self.lastError = describe(error)
        }
    }

    func cancelOIDC() async {
        if let authData = oidcPendingAuthData, let client = oidcPendingClient {
            await client.abortOidcAuth(authorizationData: authData)
        }
        oidcPendingClient = nil
        oidcPendingAuthData = nil
    }

    /// Access-token login. We need user/device IDs that match the token; the SDK gives us a
    /// `Client` we can ask for them via whoami after restoring a hand-built `Session`. Since
    /// `restoreSession` requires both, we first do a one-shot REST call to /account/whoami.
    func loginWithToken(homeserverInput: String, accessToken: String) async {
        lastError = nil
        do {
            let baseURL = try await resolveHomeserver(input: homeserverInput)
            let who = try await whoami(homeserver: baseURL, token: accessToken)
            let client = try await makeClient(homeserverUrlOrServerName: baseURL.absoluteString, freshStart: true)
            let session = Session(
                accessToken: accessToken,
                refreshToken: nil,
                userId: who.userId,
                deviceId: who.deviceId ?? "unknown-device",
                homeserverUrl: baseURL.absoluteString,
                oidcData: nil,
                slidingSyncVersion: .native
            )
            try await client.restoreSession(session: session)
            try await activate(client: client, session: try client.session())
        } catch {
            self.lastError = describe(error)
        }
    }

    /// Resume a saved session on app launch. We deliberately do NOT clear the keychain
    /// on failure — a transient network blip would log the user out and force a fresh
    /// device registration on next launch, which loses encryption keys + history. Keep
    /// the session and let the user retry via the lock/login UI.
    func restore(session: Session) async {
        do {
            let client = try await makeClient(homeserverUrlOrServerName: session.homeserverUrl)
            try await client.restoreSession(session: session)
            try await activate(client: client, session: session)
        } catch {
            self.lastError = "Auto-restore failed: \(describe(error))"
        }
    }

    /// Common path once a Client has a live session: start sync, wire listeners, expose state.
    private func activate(client: Client, session: Session) async throws {
        self.client = client
        self.session = session
        KeychainStore.save(session)

        // Sync service
        let syncBuilder = client.syncService()
        let syncService = try await syncBuilder.finish()
        self.syncService = syncService

        // Observe sync state
        let stateListener = SyncStateObserver { [weak self] state in
            Task { @MainActor in self?.syncState = state }
        }
        syncStateHandle = syncService.state(listener: stateListener)

        // Room list
        let rls = syncService.roomListService()
        self.roomListService = rls
        let roomList = try await rls.allRooms()
        let listener = RoomListListener { [weak self] updates in
            Task { @MainActor in self?.handleRoomListUpdates(updates) }
        }
        self.listenerBox = listener
        let result = roomList.entriesWithDynamicAdapters(pageSize: 500, listener: listener)
        _ = result.controller().setFilter(kind: .nonLeft)
        // CRITICAL: hold the entries stream TaskHandle, otherwise the SDK stops forwarding
        // room list updates to our listener (the handle owns the subscription).
        self.entriesStreamHandle = result.entriesStream()
        self.entriesResult = result

        // Recovery state listener (so the UI can prompt for the recovery key)
        let recoveryListener = RecoveryStateObserver { [weak self] state in
            Task { @MainActor in self?.recoveryState = state }
        }
        let encryption = client.encryption()
        recoveryStateHandle = encryption.recoveryStateListener(listener: recoveryListener)
        self.recoveryState = encryption.recoveryState()

        // Device verification state.
        let verificationListener = VerificationObserver { [weak self] state in
            Task { @MainActor in self?.verificationState = state }
        }
        verificationStateHandle = encryption.verificationStateListener(listener: verificationListener)
        self.verificationState = encryption.verificationState()

        await syncService.start()

        // Force the SDK to finish setting up encryption: this triggers device key
        // generation + upload to /keys/upload if it hasn't happened yet. Without this
        // the server returns no device keys for our session, and other clients show us
        // as "doesn't support encryption".
        await encryption.waitForE2eeInitializationTasks()

        // SAS verification controller. Other devices can initiate verification of this
        // device, and we can initiate verification of ourselves from another device.
        if let ctrl = try? await client.getSessionVerificationController() {
            self.verification = VerificationController(controller: ctrl, encryption: client.encryption())
        }

    }

    func logout() async {
        do {
            try await client?.logout()
        } catch {
            // Continue tearing down even if server logout fails.
        }
        try? await stop()
        KeychainStore.clear()
        session = nil
        rooms = [:]
        roomOrder = []
        invites = [:]
    }

    /// Wipe the SDK's SQLite event cache and crypto store, then immediately restore the
    /// session from keychain. The user stays logged in; the SDK re-fetches room history
    /// from the server on next sync. Use this when pagination returns stale "fully-loaded"
    /// state from a previous session's bad sweep.
    func resetSdkStore() async {
        guard let saved = KeychainStore.load() else { return }
        try? await stop()
        // Wipe data + cache paths (SQLite, event cache, crypto keys).
        let _ = try? sessionPaths(wipe: true)
        rooms = [:]
        roomOrder = []
        invites = [:]
        // Rebuild the client from scratch with the same session — no re-auth needed.
        do {
            let freshClient = try await makeClient(homeserverUrlOrServerName: saved.homeserverUrl, freshStart: true)
            try await freshClient.restoreSession(session: saved)
            try await activate(client: freshClient, session: saved)
        } catch {
            lastError = "Store reset failed: \(describe(error))"
        }
    }

    private func stop() async throws {
        syncStateHandle = nil
        recoveryStateHandle = nil
        verificationStateHandle = nil
        entriesStreamHandle = nil
        entriesResult = nil
        listenerBox = nil
        verification = nil
        await syncService?.stop()
        syncService = nil
        roomListService = nil
        client = nil
    }

    // MARK: - Room list updates

    private func handleRoomListUpdates(_ updates: [RoomListEntriesUpdate]) {
        // Build a flat working list from the current sidebar order, apply diffs, then re-publish.
        var current: [Room] = roomOrder.compactMap { rooms[$0]?.room }
        for upd in updates {
            switch upd {
            case .append(let values):
                current.append(contentsOf: values)
            case .clear:
                current.removeAll()
            case .pushFront(let value):
                current.insert(value, at: 0)
            case .pushBack(let value):
                current.append(value)
            case .popFront:
                if !current.isEmpty { current.removeFirst() }
            case .popBack:
                if !current.isEmpty { current.removeLast() }
            case .insert(let index, let value):
                let i = min(Int(index), current.count)
                current.insert(value, at: i)
            case .set(let index, let value):
                let i = Int(index)
                if i < current.count { current[i] = value }
                else { current.append(value) }
            case .remove(let index):
                let i = Int(index)
                if i < current.count { current.remove(at: i) }
            case .truncate(let length):
                if current.count > Int(length) {
                    current.removeLast(current.count - Int(length))
                }
            case .reset(let values):
                current = values
            }
        }

        var newOrder: [String] = []
        var newRooms: [String: RoomVM] = [:]
        var newInvites: [String: RoomVM] = [:]
        for room in current {
            let id = room.id()
            let vm = rooms[id] ?? invites[id] ?? RoomVM(room: room, session: self)
            vm.update(room: room)
            switch room.membership() {
            case .invited:
                newInvites[id] = vm
            default:
                newRooms[id] = vm
                newOrder.append(id)
            }
        }
        // Detach timelines for rooms that are gone.
        for (id, vm) in rooms where newRooms[id] == nil && newInvites[id] == nil {
            vm.detach()
        }
        rooms = newRooms
        roomOrder = newOrder
        invites = newInvites

        // Warm every room's timeline once, in the background, so opening any
        // chat is just rendering (no load wait). openTimeline() is idempotent;
        // we go sequentially to avoid a thundering herd on launch.
        if !didPreloadTimelines && !newOrder.isEmpty {
            didPreloadTimelines = true
            let vms = newOrder.compactMap { newRooms[$0] }
            Task { for vm in vms { await vm.openTimeline() } }
        }
    }

    // MARK: - Top-level actions

    func createRoom(name: String?, topic: String?, isDirect: Bool, invite: [String], encrypted: Bool) async -> String? {
        do {
            let params = CreateRoomParameters(
                name: name,
                topic: topic,
                isEncrypted: encrypted,
                isDirect: isDirect,
                visibility: .private,
                preset: isDirect ? .trustedPrivateChat : .privateChat,
                invite: invite.isEmpty ? nil : invite,
                avatar: nil,
                powerLevelContentOverride: nil,
                joinRuleOverride: nil,
                historyVisibilityOverride: nil,
                canonicalAlias: nil,
                isSpace: false
            )
            return try await client?.createRoom(request: params)
        } catch {
            lastError = describe(error)
            return nil
        }
    }

    func joinByAliasOrId(_ identifier: String) async {
        do {
            _ = try await client?.joinRoomByIdOrAlias(roomIdOrAlias: identifier, serverNames: [])
        } catch {
            lastError = describe(error)
        }
    }

    func acceptInvite(_ roomId: String) async {
        do {
            _ = try await client?.joinRoomById(roomId: roomId)
        } catch { lastError = describe(error) }
    }

    func rejectInvite(_ roomId: String) async {
        do {
            try await invites[roomId]?.room.leave()
        } catch { lastError = describe(error) }
    }

    // MARK: - Encryption / recovery

    /// Use the user's recovery key (or passphrase derived recovery key) to restore identity
    /// + key backup, then the SDK will decrypt past messages as keys arrive. After recover
    /// we wait for E2EE init tasks (cross-signing self-sign etc.) and re-check verification
    /// state for a few seconds — self-signing happens after the next sync so the state
    /// flips asynchronously.
    func recover(withKey key: String) async {
        guard let enc = client?.encryption() else { return }
        do {
            try await enc.recover(recoveryKey: key)
            await enc.waitForE2eeInitializationTasks()
            // Make sure the backup is enabled so we keep uploading keys for new sessions.
            try? await enc.enableBackups()
            // Poll verification state for up to ~10 seconds; the SDK self-signs this
            // device once it has the master secret + completes a sync.
            for _ in 0..<10 {
                let v = enc.verificationState()
                self.verificationState = v
                self.recoveryState = enc.recoveryState()
                if v == .verified { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        catch { lastError = describe(error) }
    }

    // MARK: - Helpers

    private func sessionPaths(wipe: Bool = false) throws -> (data: String, cache: String) {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = support.appendingPathComponent("MatrixClient/sdk", isDirectory: true)
        let data = base.appendingPathComponent("data", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        if wipe {
            try? fm.removeItem(at: data)
            try? fm.removeItem(at: cache)
        }
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        return (data.path, cache.path)
    }

    /// Best-effort homeserver discovery for the access-token flow.
    private func resolveHomeserver(input: String) async throws -> URL {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw SimpleError("empty homeserver") }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { throw SimpleError("bad homeserver URL") }
        // Try .well-known
        if let wk = URL(string: "/.well-known/matrix/client", relativeTo: url),
           let (data, resp) = try? await URLSession.shared.data(from: wk),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hs = obj["m.homeserver"] as? [String: Any] ?? obj["homeserver"] as? [String: Any],
           let base = hs["base_url"] as? String, let resolved = URL(string: base) {
            return resolved
        }
        return url
    }

    private struct Whoami { let userId: String; let deviceId: String? }
    private func whoami(homeserver: URL, token: String) async throws -> Whoami {
        let url = homeserver.appendingPathComponent("/_matrix/client/v3/account/whoami")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SimpleError("whoami failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = obj["user_id"] as? String else {
            throw SimpleError("whoami returned unexpected payload")
        }
        return Whoami(userId: userId, deviceId: obj["device_id"] as? String)
    }
}

// MARK: - Listener boxes (the SDK passes them across the FFI boundary, must be classes)

final class SyncStateObserver: SyncServiceStateObserver, @unchecked Sendable {
    let cb: @Sendable (SyncServiceState) -> Void
    init(_ cb: @escaping @Sendable (SyncServiceState) -> Void) { self.cb = cb }
    func onUpdate(state: SyncServiceState) { cb(state) }
}

final class RecoveryStateObserver: RecoveryStateListener, @unchecked Sendable {
    let cb: @Sendable (RecoveryState) -> Void
    init(_ cb: @escaping @Sendable (RecoveryState) -> Void) { self.cb = cb }
    func onUpdate(status: RecoveryState) { cb(status) }
}

final class VerificationObserver: VerificationStateListener, @unchecked Sendable {
    let cb: @Sendable (VerificationState) -> Void
    init(_ cb: @escaping @Sendable (VerificationState) -> Void) { self.cb = cb }
    func onUpdate(status: VerificationState) { cb(status) }
}

final class RoomListListener: RoomListEntriesListener, @unchecked Sendable {
    let cb: @Sendable ([RoomListEntriesUpdate]) -> Void
    init(_ cb: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) { self.cb = cb }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { cb(roomEntriesUpdate) }
}

// MARK: - Session delegate (token refresh persistence)

/// Called by the SDK when it refreshes the access/refresh token pair (OIDC).
/// Without this, a refreshed token is never persisted and the next app launch
/// restores the stale one, causing "invalid_grant" failures.
final class SessionDelegateBox: ClientSessionDelegate, @unchecked Sendable {
    func saveSessionInKeychain(session: Session) {
        KeychainStore.save(session)
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let session = KeychainStore.load(), session.userId == userId else {
            throw SimpleError("No keychain session for \(userId)")
        }
        return session
    }
}

// MARK: - Tiny error type for our own paths
struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}

/// Best-effort error → string. The SDK throws `ClientError`/`RoomError` enums which all conform
/// to `LocalizedError` but their associated values often carry better detail in `description`.
func describe(_ error: Error) -> String {
    if let le = error as? LocalizedError, let d = le.errorDescription { return d }
    return String(describing: error)
}
