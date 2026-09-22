import Foundation

/// Tracks how often each emoji shortcode is inserted via `:name:` autocomplete.
///
/// Kept entirely separate from `ReactionHistoryStore`, which counts hover-tray
/// reaction usage. This index is only for ranking `:name:` suggestions so that
/// frequently-used emojis float to the top of the autocomplete popup.
///
/// Counts are keyed by shortcode name (e.g. `"pensive"`, not `"😔"`).
/// All access happens on the main thread so no locking is needed.
final class EmojiUsageStore {
    static let shared = EmojiUsageStore()
    private init() { cache = Self.loadFromDefaults() }

    private static let defaultsKey = "matrixClient.emojiUsageCounts"

    /// In-memory mirror of the UserDefaults dictionary — avoids a plist decode
    /// on every keystroke (count(for:) is called ~30× per character typed).
    private var cache: [String: Int]

    /// Increment the use count for `name` and persist it.
    func record(_ name: String) {
        cache[name, default: 0] += 1
        UserDefaults.standard.set(cache, forKey: Self.defaultsKey)
    }

    /// How many times `name` has been inserted via autocomplete.
    func count(for name: String) -> Int {
        cache[name] ?? 0
    }

    private static func loadFromDefaults() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int]) ?? [:]
    }
}
