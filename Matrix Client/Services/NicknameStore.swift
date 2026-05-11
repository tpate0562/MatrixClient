import Foundation
import Combine

/// Local-only display name override per Matrix user ID. Persisted to UserDefaults so it
/// survives launches but never leaves this device.
@MainActor
final class NicknameStore: ObservableObject {
    @Published private(set) var nicknames: [String: String] = [:]

    private let defaultsKey = "matrixClient.nicknames"

    init() { load() }

    func nickname(for userId: String) -> String? {
        let v = nicknames[userId]
        return (v?.isEmpty == false) ? v : nil
    }

    /// Returns the local nickname if set, otherwise the supplied fallback, otherwise the userId.
    func displayName(for userId: String, fallback: String?) -> String {
        if let nick = nickname(for: userId) { return nick }
        if let fallback, !fallback.isEmpty { return fallback }
        return userId
    }

    func set(_ nickname: String?, for userId: String) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            nicknames[userId] = trimmed
        } else {
            nicknames.removeValue(forKey: userId)
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        nicknames = dict
    }

    private func save() {
        if let data = try? JSONEncoder().encode(nicknames) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
