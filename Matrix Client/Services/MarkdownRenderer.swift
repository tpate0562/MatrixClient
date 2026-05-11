import Foundation
import SwiftUI

/// Parses message bodies as Markdown into an `AttributedString`. Inline-only so we keep
/// chat-message line breaks intact, and we fall back to plain text on parse error.
enum MarkdownRenderer {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func render(_ body: String) -> AttributedString {
        // Plain Markdown skips raw newlines without two trailing spaces. For chat-style
        // bodies we want to preserve hard line breaks, so we normalize.
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let attr = try? AttributedString(markdown: normalized, options: options) {
            return attr
        }
        return AttributedString(normalized)
    }
}
