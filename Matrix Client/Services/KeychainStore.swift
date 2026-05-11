import Foundation
import Security
import MatrixRustSDK

/// Persists the SDK `Session` in the macOS keychain. The Session is a value type so we
/// serialize it via a side struct (SDK Session isn't Codable).
enum KeychainStore {
    private static let service = "tejaspatel.Matrix-Client.session"
    private static let account = "current"

    struct StoredSession: Codable {
        let accessToken: String
        let refreshToken: String?
        let userId: String
        let deviceId: String
        let homeserverUrl: String
        let oidcData: String?
        let slidingSync: String   // "native" | "none"
    }

    static func save(_ session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oidcData: session.oidcData,
            slidingSync: {
                switch session.slidingSyncVersion {
                case .none: return "none"
                case .native: return "native"
                }
            }()
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Session? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            return nil
        }
        return Session(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userId,
            deviceId: stored.deviceId,
            homeserverUrl: stored.homeserverUrl,
            oidcData: stored.oidcData,
            slidingSyncVersion: stored.slidingSync == "native" ? .native : .none
        )
    }

    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
