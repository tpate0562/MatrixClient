import SwiftUI

struct EmojiPickerView: View {
    let onPick: (String) -> Void
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private struct Category: Identifiable {
        let name: String
        let emojis: [EmojiData.Emoji]
        var id: String { name }
    }

    private static let categories: [Category] = {
        let all = EmojiData.all
        let topNames = ["thumbsup","thumbsdown","heart","joy","open_mouth","cry","tada","fire",
                        "rocket","100","eyes","pray","skull","white_check_mark","x","star",
                        "bulb","raised_hands","clap","thinking"]
        let topEmojis = topNames.compactMap { n in all.first { $0.name == n } }
        return [
            Category(name: "Reactions",         emojis: topEmojis),
            Category(name: "Smileys & Emotion", emojis: Array(all[0..<102])),
            Category(name: "People & Gestures", emojis: Array(all[102..<168])),
            Category(name: "Hearts & Symbols",  emojis: Array(all[168..<287])),
            Category(name: "Animals & Nature",  emojis: Array(all[287..<344])),
            Category(name: "Food & Drink",      emojis: Array(all[344..<397])),
            Category(name: "Travel & Places",   emojis: Array(all[397..<430])),
            Category(name: "Objects & Misc",    emojis: Array(all[430...])),
        ]
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick an emoji").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12).padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if query.isEmpty {
                        ForEach(Self.categories) { cat in
                            Text(cat.name)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)
                            ) {
                                ForEach(cat.emojis) { emoji in
                                    emojiButton(emoji)
                                }
                            }
                        }
                    } else {
                        let results = EmojiData.search(query, limit: 200)
                        if results.isEmpty {
                            Text("No results for \"\(query)\"")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        } else {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)
                            ) {
                                ForEach(results) { emoji in
                                    emojiButton(emoji)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 460, height: 480)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func emojiButton(_ emoji: EmojiData.Emoji) -> some View {
        Button { onPick(emoji.char); dismiss() } label: {
            Text(emoji.char)
                .font(.system(size: 22))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(":\(emoji.name):")
    }
}
