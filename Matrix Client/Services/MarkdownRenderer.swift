import Foundation
import SwiftUI
import AppKit
import MatrixRustSDK

/// Parses message bodies into an `AttributedString` for `Text(_:)`. Prefers Matrix's
/// HTML `formatted_body` when present, falls back to Markdown.
///
/// We pre-process Matrix-specific markup before handing HTML to `NSAttributedString` so
/// rainbow color spans (`data-mx-color`) and background colors (`data-mx-bg-color`) survive
/// the conversion. Spoiler spans (`data-mx-spoiler`) are rewritten depending on whether
/// the caller wants them revealed.
enum MarkdownRenderer {
    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static var cache: [CacheKey: AttributedString] = [:]
    private static let cacheLimit = 1000

    private struct CacheKey: Hashable {
        let kind: Int   // 0 markdown, 1 html-hidden, 2 html-revealed
        let body: String
    }

    /// Main entry point. `revealSpoilers` controls whether spans tagged `data-mx-spoiler`
    /// are visible or hidden behind a placeholder.
    static func render(body: String, formatted: FormattedBody?, revealSpoilers: Bool = false) -> AttributedString {
        if let formatted, case .html = formatted.format, !formatted.body.isEmpty {
            let kind = revealSpoilers ? 2 : 1
            return cached(key: CacheKey(kind: kind, body: formatted.body)) {
                renderHTML(formatted.body, fallback: body, revealSpoilers: revealSpoilers)
            }
        }
        return cached(key: CacheKey(kind: 0, body: body)) {
            renderMarkdown(body)
        }
    }

    /// Returns true if the message contains any `data-mx-spoiler` spans so the row
    /// can offer a "reveal" tap target.
    static func hasSpoilers(_ formatted: FormattedBody?) -> Bool {
        guard let formatted, case .html = formatted.format else { return false }
        return formatted.body.contains("data-mx-spoiler")
    }

    /// Plain text → markdown render. Used by composer previews and emote suffixes.
    static func render(_ body: String) -> AttributedString {
        cached(key: CacheKey(kind: 0, body: body)) { renderMarkdown(body) }
    }

    // MARK: - Implementation

    private static func renderMarkdown(_ body: String) -> AttributedString {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let attr = try? AttributedString(markdown: normalized, options: markdownOptions) {
            return attr
        }
        return AttributedString(normalized)
    }

    private static func renderHTML(_ html: String, fallback: String, revealSpoilers: Bool) -> AttributedString {
        let prepared = preprocess(html: html, revealSpoilers: revealSpoilers)
        guard let data = prepared.data(using: .utf8) else {
            return renderMarkdown(fallback)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return renderMarkdown(fallback)
        }
        let mutable = NSMutableAttributedString(attributedString: ns)
        // Strip the font attribute the HTML parser stamps everywhere, so SwiftUI's Text
        // typography takes over (color, size, weight from the call site).
        let range = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.font, range: range)
        // Trim trailing newline the HTML parser tends to append.
        let trimmed = mutable.string.hasSuffix("\n")
            ? mutable.attributedSubstring(from: NSRange(location: 0, length: mutable.length - 1))
            : mutable
        return AttributedString(trimmed)
    }

    /// Convert Matrix-specific HTML attributes to inline CSS the system parser understands.
    /// - `data-mx-color="#xxx"`     → `style="color:#xxx"`
    /// - `data-mx-bg-color="#xxx"`  → `style="background-color:#xxx"`
    /// - `data-mx-spoiler`          → either hidden block-style or revealed text
    private static func preprocess(html: String, revealSpoilers: Bool) -> String {
        var s = html
        s = s.replacingMatches(
            pattern: #"data-mx-color\s*=\s*"([^"]+)""#,
            with: { "style=\"color:\($0)\"" }
        )
        s = s.replacingMatches(
            pattern: #"data-mx-bg-color\s*=\s*"([^"]+)""#,
            with: { "style=\"background-color:\($0)\"" }
        )
        // Spoilers — either fully hide (same-color text + tint) or just keep
        // them rendered normally for the revealed mode.
        if revealSpoilers {
            s = s.replacingMatches(pattern: #"data-mx-spoiler\s*(=\s*"[^"]*")?"#, with: { _ in "" })
        } else {
            // Convert each spoiler span into an opaque box, regardless of content.
            s = s.replacingMatches(
                pattern: #"<span\s+data-mx-spoiler\s*(=\s*"[^"]*")?\s*>([\s\S]*?)</span>"#,
                template: "<span style=\"background-color:#444;color:#444;border-radius:3px\">$2</span>"
            )
        }
        return s
    }

    private static func cached(key: CacheKey, build: () -> AttributedString) -> AttributedString {
        if let hit = cache[key] { return hit }
        let value = build()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = value
        return value
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

    /// Template-style replacement (`$1`, `$2`, etc.) via NSRegularExpression.
    func replacingMatches(pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return self
        }
        return regex.stringByReplacingMatches(
            in: self,
            range: NSRange(startIndex..., in: self),
            withTemplate: template
        )
    }
}
