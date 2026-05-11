import Foundation
import SwiftUI
import AppKit
import MatrixRustSDK

/// Renders message bodies as `AttributedString`. Prefers Matrix's `formatted_body` HTML
/// (preserving rainbow colors and spoilers) and falls back to Markdown.
///
/// Spoiler implementation: each `<span data-mx-spoiler>` becomes an `<a href="spoiler://N">`
/// link assigned a sequential index. The post-processor styles the link as an opaque
/// redaction box. The caller passes in a `Set<Int>` of revealed indices; only the
/// revealed indices render as normal text.
enum MarkdownRenderer {
    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static var cache: [CacheKey: AttributedString] = [:]
    private static let cacheLimit = 1000

    private struct CacheKey: Hashable {
        let kind: Int   // 0 markdown, 1 html
        let body: String
        let revealed: [Int]   // sorted
    }

    /// Returns rendered text + total spoiler count.
    static func render(body: String, formatted: FormattedBody?, revealedSpoilers: Set<Int>) -> (AttributedString, spoilerCount: Int) {
        if let formatted, case .html = formatted.format, !formatted.body.isEmpty {
            let key = CacheKey(kind: 1, body: formatted.body, revealed: revealedSpoilers.sorted())
            if let hit = cache[key] {
                return (hit, countSpoilers(in: formatted.body))
            }
            let (attr, count) = renderHTML(formatted.body, fallback: body, revealed: revealedSpoilers)
            if cache.count >= cacheLimit { cache.removeAll() }
            cache[key] = attr
            return (attr, count)
        }
        let key = CacheKey(kind: 0, body: body, revealed: [])
        if let hit = cache[key] { return (hit, 0) }
        let attr = renderMarkdown(body)
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = attr
        return (attr, 0)
    }

    /// Plain text → markdown render. Used by composer previews and emote suffixes.
    static func render(_ body: String) -> AttributedString {
        renderMarkdown(body)
    }

    // MARK: - Implementation

    private static func renderMarkdown(_ body: String) -> AttributedString {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let attr = try? AttributedString(markdown: normalized, options: markdownOptions) {
            return attr
        }
        return AttributedString(normalized)
    }

    private static func renderHTML(_ html: String, fallback: String, revealed: Set<Int>) -> (AttributedString, Int) {
        let (prepared, count) = preprocess(html: html, revealed: revealed)
        guard let data = prepared.data(using: .utf8) else {
            return (renderMarkdown(fallback), count)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return (renderMarkdown(fallback), count)
        }
        let mutable = NSMutableAttributedString(attributedString: ns)
        let range = NSRange(location: 0, length: mutable.length)
        // Strip the font attribute the HTML parser stamps everywhere, so SwiftUI's Text
        // typography takes over.
        mutable.removeAttribute(.font, range: range)
        // Style any spoiler link runs: hide underline, set fg = bg, opaque dark box.
        mutable.enumerateAttribute(.link, in: range) { value, runRange, _ in
            guard let url = value as? URL, url.scheme == "spoiler" else { return }
            let box = NSColor(white: 0.27, alpha: 1.0)
            mutable.addAttribute(.foregroundColor, value: box, range: runRange)
            mutable.addAttribute(.backgroundColor, value: box, range: runRange)
            mutable.removeAttribute(.underlineStyle, range: runRange)
            mutable.addAttribute(.underlineStyle, value: 0, range: runRange)
        }
        // Trim trailing newline the HTML parser tends to append.
        let trimmed = mutable.string.hasSuffix("\n")
            ? mutable.attributedSubstring(from: NSRange(location: 0, length: mutable.length - 1))
            : mutable
        return (AttributedString(trimmed), count)
    }

    private static func countSpoilers(in html: String) -> Int {
        // Cheap count — matches the regex used in preprocess.
        let regex = try? NSRegularExpression(pattern: #"data-mx-spoiler"#, options: [.caseInsensitive])
        return regex?.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) ?? 0
    }

    /// Convert Matrix-specific HTML attributes to inline CSS the system parser understands,
    /// and rewrite spoiler spans into `<a>` link runs with sequential indices so we can
    /// hit-test them individually.
    private static func preprocess(html: String, revealed: Set<Int>) -> (String, Int) {
        var s = html
        s = s.replacingMatches(
            pattern: #"data-mx-color\s*=\s*"([^"]+)""#,
            with: { "style=\"color:\($0)\"" }
        )
        s = s.replacingMatches(
            pattern: #"data-mx-bg-color\s*=\s*"([^"]+)""#,
            with: { "style=\"background-color:\($0)\"" }
        )

        // Walk spoilers and rewrite each one to either a normal <span> (if revealed) or
        // an <a href="spoiler://N"> (if hidden). Index is incremented per occurrence.
        let pattern = #"<span\s+data-mx-spoiler\s*(=\s*"[^"]*")?\s*>([\s\S]*?)</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (s, 0)
        }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return (s, 0) }
        var out = ""
        var cursor = s.startIndex
        var idx = 0
        for match in matches {
            guard let full = Range(match.range, in: s) else { continue }
            out.append(contentsOf: s[cursor..<full.lowerBound])
            let inner: String
            if match.numberOfRanges > 2, let innerR = Range(match.range(at: 2), in: s) {
                inner = String(s[innerR])
            } else {
                inner = ""
            }
            if revealed.contains(idx) {
                out += "<span>\(inner)</span>"
            } else {
                // The visual styling is set after parsing (see renderHTML above) — keep
                // the inline style minimal here.
                out += "<a href=\"spoiler://\(idx)\">\(inner)</a>"
            }
            idx += 1
            cursor = full.upperBound
        }
        out.append(contentsOf: s[cursor...])
        return (out, idx)
    }
}

// MARK: - Helpers

private extension String {
    /// Replace every regex match by running a closure on the first capture group.
    func replacingMatches(pattern: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return self
        }
        let matches = regex.matches(in: self, range: NSRange(startIndex..., in: self))
        guard !matches.isEmpty else { return self }
        var out = ""
        var cursor = startIndex
        for match in matches {
            guard let range = Range(match.range, in: self) else { continue }
            out.append(contentsOf: self[cursor..<range.lowerBound])
            if match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: self) {
                out.append(transform(String(self[captureRange])))
            } else {
                out.append(transform(""))
            }
            cursor = range.upperBound
        }
        out.append(contentsOf: self[cursor...])
        return out
    }
}
