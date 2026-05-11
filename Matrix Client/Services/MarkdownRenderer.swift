import Foundation
import SwiftUI
import AppKit
import MatrixRustSDK

/// Parses message bodies into an `AttributedString` suitable for `Text(_:)`. Prefers the
/// HTML `formatted_body` from Matrix when present; falls back to parsing the plain `body`
/// as Markdown.
enum MarkdownRenderer {
    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// LRU-ish cache keyed by the input string. Capped because HTML→AttributedString is
    /// expensive (uses WebKit under the hood) and timelines can have thousands of messages.
    private static var cache: [CacheKey: AttributedString] = [:]
    private static let cacheLimit = 1000

    private struct CacheKey: Hashable {
        let html: Bool
        let body: String
    }

    /// Main entry point. `formatted` is the Matrix `FormattedBody` from the timeline.
    static func render(body: String, formatted: FormattedBody?) -> AttributedString {
        if let formatted, case .html = formatted.format, !formatted.body.isEmpty {
            return cached(key: CacheKey(html: true, body: formatted.body)) {
                renderHTML(formatted.body, fallback: body)
            }
        }
        return cached(key: CacheKey(html: false, body: body)) {
            renderMarkdown(body)
        }
    }

    /// Plain-text input — parses the input string as Markdown.
    static func render(_ body: String) -> AttributedString {
        cached(key: CacheKey(html: false, body: body)) {
            renderMarkdown(body)
        }
    }

    // MARK: - Implementation

    private static func renderMarkdown(_ body: String) -> AttributedString {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let attr = try? AttributedString(markdown: normalized, options: markdownOptions) {
            return attr
        }
        return AttributedString(normalized)
    }

    private static func renderHTML(_ html: String, fallback: String) -> AttributedString {
        guard let data = html.data(using: .utf8) else {
            return renderMarkdown(fallback)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return renderMarkdown(fallback)
        }
        // The HTML parser ships system fonts that don't always match SwiftUI's body. Strip
        // the font attribute so SwiftUI's Text view styles take over.
        let mutable = NSMutableAttributedString(attributedString: ns)
        let range = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.font, range: range)
        // Trim a trailing newline that the HTML parser tends to append.
        let trimmed = mutable.string.hasSuffix("\n")
            ? mutable.attributedSubstring(from: NSRange(location: 0, length: mutable.length - 1))
            : mutable
        return AttributedString(trimmed)
    }

    private static func cached(key: CacheKey, build: () -> AttributedString) -> AttributedString {
        if let hit = cache[key] { return hit }
        let value = build()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = value
        return value
    }
}
