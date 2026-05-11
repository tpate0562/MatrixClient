import SwiftUI
import MatrixRustSDK

struct ReactionsBar: View {
    let reactions: [Reaction]
    let myUserId: String?
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.key) { r in
                let mine = myUserId.map { me in r.senders.contains(where: { $0.senderId == me }) } ?? false
                Button { onTap(r.key) } label: {
                    HStack(spacing: 3) {
                        Text(r.key)
                        Text("\(r.senders.count)").font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(mine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(mine ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(r.senders.map { $0.senderId }.joined(separator: ", "))
            }
        }
    }
}
