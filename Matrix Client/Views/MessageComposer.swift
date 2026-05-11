import SwiftUI
import MatrixRustSDK

struct MessageComposer: View {
    @Binding var text: String
    @Binding var replyingToId: String?
    @ObservedObject var room: RoomVM
    let onSend: () -> Void
    let onEmoji: () -> Void

    @FocusState private var focused: Bool
    @State private var lastTypingSent: Date?
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            if let replyingToId {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.up.left")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to message").font(.caption.bold())
                        Text(replyingToId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingToId = nil } label: {
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
                    Image(systemName: "face.smiling").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Insert emoji")

                TextField(
                    room.isEncrypted ? "🔒 Send an encrypted message…" : "Send a message…",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSend)
                .onChange(of: text) { _, newValue in handleTextChange(newValue) }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.background)
        .onAppear { focused = true }
        .onDisappear {
            stopTask?.cancel()
            Task { await room.setTyping(false) }
        }
    }

    private func handleTextChange(_ newValue: String) {
        let now = Date()
        if newValue.isEmpty {
            stopTask?.cancel()
            Task { await room.setTyping(false) }
            lastTypingSent = nil
            return
        }
        if lastTypingSent == nil || now.timeIntervalSince(lastTypingSent!) > 10 {
            Task { await room.setTyping(true) }
            lastTypingSent = now
        }
        stopTask?.cancel()
        stopTask = Task { [room] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                await room.setTyping(false)
                await MainActor.run { lastTypingSent = nil }
            }
        }
    }
}
