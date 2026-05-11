import SwiftUI

struct MessageComposer: View {
    @Binding var text: String
    @Binding var replyingTo: MatrixEvent?
    let isEncrypted: Bool
    @ObservedObject var room: Room
    let onSend: () -> Void
    let onEmoji: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let replyingTo {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.up.left")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(room.memberDisplayName(replyingTo.sender) ?? replyingTo.sender)")
                            .font(.caption.bold())
                        Text(replyingTo.messageBody ?? "(\(replyingTo.type))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onEmoji) {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Insert emoji")

                TextField(
                    isEncrypted
                        ? "🔒 Send a message (encrypted — body will be sent unencrypted by this client)"
                        : "Send a message…",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSend)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.background)
        .onAppear { focused = true }
    }
}
