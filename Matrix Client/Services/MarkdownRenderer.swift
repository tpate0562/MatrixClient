import Foundation
import SwiftUI
import AppKit
import MatrixRustSDK

/// Renders message bodies as a list of `Segment`s. Prefers Matrix's `formatted_body` HTML
/// (preserving rainbow colors and spoilers) and falls back to Markdown.
///
/// **Code blocks are returned as a separate segment kind** so the view layer can wrap
/// them in a bordered, dark-backed container (`CodeBlockView`) — NSAttributedString's
/// `background-color` only paints behind glyphs, so a full-block background needs its
/// own SwiftUI view rather than living inside the text run.
///
/// Spoiler implementation: each `<span data-mx-spoiler>` becomes an `<a href="spoiler://N">`
/// link assigned a sequential index. The post-processor styles the link as an opaque
/// redaction box. Spoiler indices are continuous across text segments, so revealing one
/// spoiler doesn't shift the IDs of later ones.
enum MarkdownRenderer {
    /// One piece of a rendered message. `text` chunks carry inline formatting (spoilers,
    /// bold/italic, links, inline `<code>`); `codeBlock` chunks carry raw source plus an
    /// optional language tag for `CodeBlockView` to syntax-highlight.
    enum Segment {
        case text(AttributedString)
        case codeBlock(language: String?, code: String)
    }

    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private struct CacheValue {
        let segments: [Segment]
        let spoilerCount: Int
    }

    private static var cache: [CacheKey: CacheValue] = [:]
    private static let cacheLimit = 1000

    private struct CacheKey: Hashable {
        let kind: Int   // 0 markdown, 1 html
        let body: String
        let revealed: [Int]   // sorted
    }

    /// Returns rendered segments + total spoiler count.
    static func render(body: String, formatted: FormattedBody?, revealedSpoilers: Set<Int>) -> (segments: [Segment], spoilerCount: Int) {
        if let formatted, case .html = formatted.format, !formatted.body.isEmpty {
            let key = CacheKey(kind: 1, body: formatted.body, revealed: revealedSpoilers.sorted())
            if let hit = cache[key] {
                return (hit.segments, hit.spoilerCount)
            }
            let (segs, count) = renderHTMLAsSegments(formatted.body, fallback: body, revealed: revealedSpoilers)
            if cache.count >= cacheLimit { cache.removeAll() }
            cache[key] = CacheValue(segments: segs, spoilerCount: count)
            return (segs, count)
        }
        let key = CacheKey(kind: 0, body: body, revealed: [])
        if let hit = cache[key] { return (hit.segments, hit.spoilerCount) }
        let segs: [Segment] = [.text(renderMarkdown(body))]
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = CacheValue(segments: segs, spoilerCount: 0)
        return (segs, 0)
    }

    /// Plain text → markdown render. Used by composer previews and emote suffixes.
    static func render(_ body: String) -> AttributedString {
        renderMarkdown(body)
    }

    /// Flatten segments into a single `AttributedString` for callers that can't render
    /// the bordered code-block chrome (the emote path, in-bubble inline composition).
    /// Code blocks become inline monospaced runs.
    static func flatten(_ segments: [Segment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let attr):
                result.append(attr)
            case .codeBlock(_, let code):
                var part = AttributedString(code)
                part.font = .system(.body, design: .monospaced)
                result.append(part)
            }
        }
        return result
    }

    // MARK: - Implementation

    private static func renderMarkdown(_ body: String) -> AttributedString {
        var normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        // In Markdown, a single newline is a soft break (just a space). For chat
        // messages, users expect newlines to be preserved. Two trailing spaces
        // before a newline forces a hard line break in Markdown.
        // Only convert SINGLE newlines — double newlines are already paragraph
        // breaks and must be preserved as-is for blank lines.
        normalized = normalized.replacingOccurrences(
            of: "(?<!\n)\n(?!\n)", with: "  \n",
            options: .regularExpression
        )
        if var attr = try? AttributedString(markdown: normalized, options: markdownOptions) {
            attr = addLinks(attr)
            return attr
        }
        return addLinks(AttributedString(body))
    }

    private static func addLinks(_ attr: AttributedString) -> AttributedString {
        var result = attr
        let string = String(attr.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attr }
        let matches = detector.matches(in: string, options: [], range: NSRange(location: 0, length: string.utf16.count))
        
        for match in matches {
            guard let url = match.url else { continue }
            guard let range = Range(match.range, in: string) else { continue }
            guard let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            
            let attrRange = start..<end
            // Check if any part of the range already has a link
            var hasLink = false
            for run in result[attrRange].runs {
                if run.link != nil {
                    hasLink = true
                    break
                }
            }
            if !hasLink {
                result[attrRange].link = url
            }
        }
        return result
    }

    /// Split the HTML at `<pre><code>` boundaries so the view layer can render the code
    /// blocks separately. Text in between is rendered via the regular HTML pipeline.
    /// Spoiler indices are continuous across segments — each call to `renderHTML` is
    /// passed the running total so revealing one block doesn't renumber later blocks.
    private static func renderHTMLAsSegments(_ html: String, fallback: String, revealed: Set<Int>) -> ([Segment], Int) {
        let pattern = #"<pre(?:\s+[^>]*)?>\s*<code([^>]*)>([\s\S]*?)</code>\s*</pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            let (attr, count) = renderHTML(html, fallback: fallback, revealed: revealed, spoilerOffset: 0)
            return ([.text(attr)], count)
        }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        if matches.isEmpty {
            let (attr, count) = renderHTML(html, fallback: fallback, revealed: revealed, spoilerOffset: 0)
            return ([.text(attr)], count)
        }

        var segments: [Segment] = []
        var cursor = html.startIndex
        var totalSpoilers = 0

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let full = Range(match.range, in: html),
                  let attrR = Range(match.range(at: 1), in: html),
                  let innerR = Range(match.range(at: 2), in: html) else { continue }

            // Render any text that appeared before this code block.
            let textHTML = String(html[cursor..<full.lowerBound])
            if !textHTML.isEmpty {
                let (attr, count) = renderHTML(textHTML, fallback: "", revealed: revealed, spoilerOffset: totalSpoilers)
                if !String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(attr))
                }
                totalSpoilers += count
            }

            // Hand the code block off as raw source — `CodeBlockView` does the highlighting.
            let language = extractLanguageClass(from: String(html[attrR]))
            let rawCode = decodeHTMLEntities(String(html[innerR]))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            segments.append(.codeBlock(language: language, code: rawCode))

            cursor = full.upperBound
        }

        // Trailing text after the final code block.
        let trailingHTML = String(html[cursor...])
        if !trailingHTML.isEmpty {
            let (attr, count) = renderHTML(trailingHTML, fallback: "", revealed: revealed, spoilerOffset: totalSpoilers)
            if !String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(attr))
            }
            totalSpoilers += count
        }

        if segments.isEmpty {
            // Defensive: if everything got filtered out (e.g. message was only a code
            // block and the regex didn't match anything else), at least return something.
            let (attr, count) = renderHTML(html, fallback: fallback, revealed: revealed, spoilerOffset: 0)
            return ([.text(attr)], count)
        }
        return (segments, totalSpoilers)
    }

    private static func renderHTML(_ html: String, fallback: String, revealed: Set<Int>, spoilerOffset: Int) -> (AttributedString, Int) {
        let (prepared, count) = preprocess(html: html, revealed: revealed, spoilerOffset: spoilerOffset)
        // Wrap in a basic HTML template so the parser picks up our base font size.
        let wrapped = """
        <style>
        body { font-family: -apple-system; font-size: 13px; }
        </style>
        \(prepared)
        """
        guard let data = wrapped.data(using: .utf8) else {
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
        // Process fonts: preserve heading sizes and bold/italic traits.
        // The HTML parser assigns specific point sizes for headings (e.g. ~24pt for H1,
        // ~18pt for H2, etc). We detect these and map to reasonable chat sizes.
        let baseFontSize: CGFloat = 13
        // Heading size thresholds: anything > 14pt is a heading
        let headingSizes: [(threshold: CGFloat, size: CGFloat, weight: NSFont.Weight)] = [
            (23, 22, .bold),   // H1
            (17, 18, .bold),   // H2
            (14, 15, .semibold), // H3
        ]
        mutable.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let pointSize = font.pointSize

            // Monospaced runs (inline `<code>`, `<pre><code>` blocks) — standardize on
            // SF Mono at chat size so the parser's default Courier doesn't dominate.
            if traits.contains(.monoSpace) || font.isFixedPitch {
                let monoSize: CGFloat = baseFontSize - 1
                var monoFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
                if traits.contains(.bold) {
                    monoFont = NSFontManager.shared.convert(monoFont, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italic) {
                    monoFont = NSFontManager.shared.convert(monoFont, toHaveTrait: .italicFontMask)
                }
                mutable.addAttribute(.font, value: monoFont, range: runRange)
                return
            }

            // Check if this is a heading (by font size)
            var matchedHeading = false
            for heading in headingSizes {
                if pointSize >= heading.threshold {
                    var headingFont = NSFont.systemFont(ofSize: heading.size, weight: heading.weight)
                    if traits.contains(.italic) {
                        headingFont = NSFontManager.shared.convert(headingFont, toHaveTrait: .italicFontMask)
                    }
                    mutable.addAttribute(.font, value: headingFont, range: runRange)
                    matchedHeading = true
                    break
                }
            }
            if matchedHeading { return }

            // Normal text — preserve bold/italic traits at base size
            if traits.contains(.bold) && traits.contains(.italic) {
                let biFont = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: baseFontSize, weight: .bold),
                    toHaveTrait: .italicFontMask
                )
                mutable.addAttribute(.font, value: biFont, range: runRange)
            } else if traits.contains(.bold) {
                mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: baseFontSize, weight: .bold), range: runRange)
            } else if traits.contains(.italic) {
                let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: baseFontSize), toHaveTrait: .italicFontMask)
                mutable.addAttribute(.font, value: italicFont, range: runRange)
            } else {
                // Plain text — strip the font so SwiftUI uses its own typography.
                mutable.removeAttribute(.font, range: runRange)
            }
        }
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

    /// Convert Matrix-specific HTML attributes to inline CSS the system parser understands,
    /// and rewrite spoiler spans into `<a>` link runs. `spoilerOffset` is the running count
    /// of spoilers in earlier text segments — added to the local index so the final
    /// `spoiler://N` URLs are unique across the whole message.
    private static func preprocess(html: String, revealed: Set<Int>, spoilerOffset: Int) -> (String, Int) {
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
        // an <a href="spoiler://N"> (if hidden). N is the GLOBAL index across all segments.
        let pattern = #"<span\s+data-mx-spoiler\s*(=\s*"[^"]*")?\s*>([\s\S]*?)</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (s, 0)
        }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return (s, 0) }
        var out = ""
        var cursor = s.startIndex
        var localIdx = 0
        for match in matches {
            guard let full = Range(match.range, in: s) else { continue }
            out.append(contentsOf: s[cursor..<full.lowerBound])
            let inner: String
            if match.numberOfRanges > 2, let innerR = Range(match.range(at: 2), in: s) {
                inner = String(s[innerR])
            } else {
                inner = ""
            }
            let globalIdx = spoilerOffset + localIdx
            if revealed.contains(globalIdx) {
                out += "<span>\(inner)</span>"
            } else {
                // The visual styling is set after parsing (see renderHTML above) — keep
                // the inline style minimal here.
                out += "<a href=\"spoiler://\(globalIdx)\">\(inner)</a>"
            }
            localIdx += 1
            cursor = full.upperBound
        }
        out.append(contentsOf: s[cursor...])
        return (out, localIdx)
    }

    private static func extractLanguageClass(from tagAttrs: String) -> String? {
        let pattern = #"class\s*=\s*"language-([^"\s]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let r = NSRange(tagAttrs.startIndex..., in: tagAttrs)
        guard let m = regex.firstMatch(in: tagAttrs, range: r),
              m.numberOfRanges > 1,
              let lr = Range(m.range(at: 1), in: tagAttrs) else { return nil }
        return String(tagAttrs[lr])
    }

    /// Decode the named HTML entities that Matrix HTML uses inside code blocks.
    /// Order matters: `&amp;` must be decoded last so `&amp;lt;` round-trips to `&lt;`,
    /// not `<`. Also handles numeric character references (`&#34;`, `&#x22;`).
    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " ")
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        out = decodeNumericEntities(out)
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        let pattern = #"&#(x?)([0-9a-fA-F]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = s.startIndex
        for match in matches {
            guard let full = Range(match.range, in: s),
                  let prefixR = Range(match.range(at: 1), in: s),
                  let digitsR = Range(match.range(at: 2), in: s) else { continue }
            out.append(contentsOf: s[cursor..<full.lowerBound])
            let isHex = !s[prefixR].isEmpty
            let digits = String(s[digitsR])
            if let code = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            } else {
                out.append(contentsOf: s[full])
            }
            cursor = full.upperBound
        }
        out.append(contentsOf: s[cursor...])
        return out
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
