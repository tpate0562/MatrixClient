import SwiftUI

/// Renders a single code block as a bordered, dark-backed container with syntax-highlighted
/// monospaced text. Lives in its own SwiftUI view so the dark chrome can extend across the
/// full width of the message bubble — `NSAttributedString`'s character-level
/// `background-color` would only paint behind individual glyphs, leaving gaps at line
/// breaks and blank lines.
///
/// Long lines scroll horizontally so the array of numbers in the Haskell sample stays
/// on a single line instead of wrapping into a wall of digits.
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        let highlighted = SyntaxHighlighter.highlight(code: code, language: language)
        VStack(alignment: .leading, spacing: 4) {
            if let label = displayLanguageLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SyntaxHighlighter.theme.comment)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SyntaxHighlighter.theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Human-friendly label for the language pill in the corner. Returns `nil` for
    /// untagged blocks so plain `<pre><code>` doesn't get a "code" header.
    private var displayLanguageLabel: String? {
        guard let language, !language.isEmpty else { return nil }
        let normalized = language.lowercased()
        let pretty: [String: String] = [
            "js": "JavaScript", "javascript": "JavaScript",
            "ts": "TypeScript", "typescript": "TypeScript",
            "py": "Python", "python": "Python",
            "rb": "Ruby", "ruby": "Ruby",
            "cs": "C#", "csharp": "C#",
            "cpp": "C++", "c++": "C++",
            "objc": "Objective-C", "objectivec": "Objective-C", "objective-c": "Objective-C",
            "sh": "Shell", "bash": "Bash", "zsh": "Zsh",
            "yml": "YAML", "yaml": "YAML",
            "kt": "Kotlin", "kotlin": "Kotlin",
            "rs": "Rust", "rust": "Rust",
            "hs": "Haskell", "haskell": "Haskell",
            "go": "Go", "golang": "Go",
            "swift": "Swift",
            "java": "Java",
            "json": "JSON",
            "html": "HTML", "xml": "XML",
            "css": "CSS", "scss": "SCSS", "sass": "Sass",
            "sql": "SQL",
            "php": "PHP",
            "lua": "Lua",
            "dart": "Dart",
            "scala": "Scala",
            "elixir": "Elixir", "ex": "Elixir",
            "perl": "Perl", "pl": "Perl",
            "r": "R"
        ]
        return pretty[normalized] ?? language
    }
}
