import SwiftUI

struct EmojiPickerView: View {
    let onPick: (String) -> Void
    @State private var query: String = ""
    @Environment(\.dismiss) private var dismiss

    private struct Category: Identifiable {
        let name: String
        let emojis: [String]
        var id: String { name }
    }

    private let categories: [Category] = [
        Category(name: "Reactions", emojis: ["👍","👎","❤️","😂","😮","😢","🎉","🔥","🚀","💯","👀","🙏","💀","✅","❌","⭐","💡","🙌","👏","🤔"]),
        Category(name: "Smileys", emojis: ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","☺️","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐","🤨","😐","😑","😶","😏","😒","🙄","😬","🤥","😌","😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🤧","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓","🧐"]),
        Category(name: "Hearts", emojis: ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💟"]),
        Category(name: "Hands", emojis: ["👍","👎","👌","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","👋","🤚","🖐","✋","🖖","👏","🙌","👐","🤲","🙏","✍️","💪","🦾","🤛","🤜","👊","✊"]),
        Category(name: "Animals", emojis: ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦","🐤","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐢","🐍","🦎","🦖","🐳","🐬","🐟","🦈","🐙","🦀"]),
        Category(name: "Food", emojis: ["🍎","🍊","🍋","🍌","🍉","🍇","🍓","🍑","🍒","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶","🌽","🥕","🧄","🧅","🥔","🍠","🥐","🥯","🍞","🥖","🧀","🥚","🍳","🥞","🧇","🥓","🍔","🍟","🍕","🌭","🥪","🌮","🌯","🥙","🍱","🍣","🍤","🍦","🍩","🍪","🎂","🍫","☕","🍵","🍷","🍺"]),
        Category(name: "Travel", emojis: ["🚗","🚕","🚙","🚌","🚎","🏎","🚓","🚑","🚒","🚐","🚚","🚛","🚜","🛵","🏍","🚲","🛴","✈️","🚀","🛸","🚁","🛶","⛵","🚤","🛳","⛴","🚢","⚓","🚉","🚊","🚝","🚞","🚋","🚃","🚄","🚅","🚆","🚇","🚈","🚂"]),
        Category(name: "Symbols", emojis: ["✅","❌","⚠️","✔️","✖️","➕","➖","➗","♾","‼️","⁉️","❓","❔","❕","❗","💲","💱","🔼","🔽","⏫","⏬","⏪","⏩","🔄","🔁","🔂","🔀","🔼","➡️","⬅️","⬆️","⬇️","↗️","↘️","↙️","↖️","↕️","↔️","🔃","🌀","🆗","🆕","🆙","🆒","🆓","🆖","💯","🔟","🆔","ℹ️"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick an emoji").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12).padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(categories) { cat in
                        let filtered = filteredEmojis(in: cat)
                        if !filtered.isEmpty {
                            Text(cat.name)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)) {
                                ForEach(filtered, id: \.self) { emoji in
                                    Button { onPick(emoji); dismiss() } label: {
                                        Text(emoji).font(.system(size: 22))
                                            .frame(width: 32, height: 32)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 460, height: 480)
    }

    private func filteredEmojis(in cat: Category) -> [String] {
        guard !query.isEmpty else { return cat.emojis }
        // Without a labeled emoji dataset we keyword-match the category name only.
        return cat.name.lowercased().contains(query.lowercased()) ? cat.emojis : []
    }
}
