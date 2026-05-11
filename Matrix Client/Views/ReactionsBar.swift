import SwiftUI

struct ReactionsBar: View {
    let reactions: [Room.Reaction]
    let myUserId: String?
    let onTap: (String) -> Void

    private struct Group: Identifiable {
        let key: String
        let count: Int
        let mine: Bool
        let senders: [String]
        var id: String { key }
    }

    private var groups: [Group] {
        var byKey: [String: [Room.Reaction]] = [:]
        for r in reactions { byKey[r.key, default: []].append(r) }
        return byKey
            .map { (k, list) in
                Group(
                    key: k,
                    count: list.count,
                    mine: myUserId.map { me in list.contains(where: { $0.sender == me }) } ?? false,
                    senders: list.map(\.sender)
                )
            }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(groups) { g in
                Button { onTap(g.key) } label: {
                    HStack(spacing: 3) {
                        Text(g.key)
                        Text("\(g.count)").font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(g.mine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(g.mine ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(g.senders.joined(separator: ", "))
            }
        }
    }
}
