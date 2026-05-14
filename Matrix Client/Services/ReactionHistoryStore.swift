import Foundation
import Combine

/// Persists per-emoji usage counts so the hover tray can surface the user's top 3 reactions.
final class ReactionHistoryStore: ObservableObject {
    @Published private(set) var top3: [String] = []

    private static let key = "matrixClient.reactionCounts"
    private static let fallbacks = ["👍", "❤️", "😂"]

    init() { refresh() }

    func record(_ emoji: String) {
        var counts = loadCounts()
        counts[emoji, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.key)
        refresh()
    }

    private func refresh() {
        let counts = loadCounts()
        var result = counts.sorted { $0.value > $1.value }.map(\.key)
        for d in Self.fallbacks where result.count < 3 && !result.contains(d) {
            result.append(d)
        }
        top3 = Array(result.prefix(3))
    }

    private func loadCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int]) ?? [:]
    }
}
