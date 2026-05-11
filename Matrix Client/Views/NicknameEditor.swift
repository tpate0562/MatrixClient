import SwiftUI

struct NicknameEditor: View {
    let userId: String
    let currentName: String

    @EnvironmentObject private var nicknames: NicknameStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Local Nickname").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(userId).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Current: \(currentName)").font(.caption).foregroundStyle(.tertiary)
            }
            TextField("Nickname (visible only to you)", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Clear", role: .destructive) {
                    nicknames.set(nil, for: userId)
                    dismiss()
                }
                .disabled(nicknames.nickname(for: userId) == nil)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    nicknames.set(draft, for: userId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear {
            draft = nicknames.nickname(for: userId) ?? ""
        }
    }
}
