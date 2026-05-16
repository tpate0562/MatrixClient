import Foundation
import MatrixRustSDK

/// Tiny slash-command pre-processor for the composer. Today: /rainbow and /spoiler.
enum SlashCommand {
    case rainbow(String)
    case spoiler(String)
    /// Multi-line message where one or more lines are their own `/spoiler` command.
    /// Carries the full original text so each such line can be hidden independently.
    case perLineSpoiler(String)
    case none(String)
}

enum SlashCommandParser {
    static func parse(_ input: String) -> SlashCommand {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body = strip(prefix: "/rainbow", from: s) { return .rainbow(body) }

        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            // Several lines, any of which is its own `/spoiler …` — hide them per-line.
            if lines.contains(where: { spoilerBody(ofLine: String($0)) != nil }) {
                return .perLineSpoiler(input)
            }
        } else if let body = strip(prefix: "/spoiler", from: s) {
            return .spoiler(body)
        }
        return .none(input)
    }

    /// If `line` (ignoring surrounding whitespace) is a `/spoiler …` command, return its
    /// spoiler content; otherwise nil. Shared by the parser and `MessageBuilder`.
    static func spoilerBody(ofLine line: String) -> String? {
        strip(prefix: "/spoiler", from: line.trimmingCharacters(in: .whitespaces))
    }

    private static func strip(prefix: String, from s: String) -> String? {
        guard s.lowercased().hasPrefix(prefix) else { return nil }
        let body = String(s.dropFirst(prefix.count))
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Build the `content` for an HTML-formatted Matrix message. `body` is the plain-text
/// representation; `formattedBody` is the HTML version.
enum MessageBuilder {
    static func rainbow(_ text: String) -> (plain: String, html: String) {
        let colors = [
            "#ff00be", "#ff006e", "#ff4608", "#ff8600", "#f1ad00",
            "#a6c700", "#28d600", "#00e48a", "#00e7e1", "#00e7ff",
            "#00e3ff", "#00c3ff", "#69a0ff", "#ff68ff", "#ff00ff",
        ]
        var html = ""
        var colorIdx = 0
        for ch in text {
            if ch.isWhitespace {
                html += String(ch)
            } else {
                let color = colors[colorIdx % colors.count]
                html += "<span data-mx-color=\"\(color)\">\(escapeHTML(String(ch)))</span>"
                colorIdx += 1
            }
        }
        return (text, html)
    }

    static func spoiler(_ text: String) -> (plain: String, html: String) {
        // Matrix spec: hidden body becomes the spoiler content, fallback text is just brackets.
        let html = "<span data-mx-spoiler>\(escapeHTML(text))</span>"
        return ("[spoiler] \(text)", html)
    }

    /// Multi-line spoilers: every line that is a `/spoiler …` command becomes its own
    /// hidden span; all other lines pass through unchanged. Blank lines are preserved.
    static func perLineSpoilers(_ text: String) -> (plain: String, html: String) {
        var plainLines: [String] = []
        var htmlLines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let body = SlashCommandParser.spoilerBody(ofLine: line) {
                plainLines.append("[spoiler] \(body)")
                htmlLines.append("<span data-mx-spoiler>\(escapeHTML(body))</span>")
            } else {
                plainLines.append(line)
                htmlLines.append(escapeHTML(line))
            }
        }
        return (plainLines.joined(separator: "\n"), htmlLines.joined(separator: "<br>"))
    }

    /// Convert Discord-style ||spoiler|| syntax to Matrix spoiler HTML.
    /// Supports multiple inline spoilers mixed with regular text.
    static func inlineSpoilers(_ text: String) -> (plain: String, html: String) {
        let pattern = "\\|\\|(.+?)\\|\\|"
        let plain = text.replacingOccurrences(
            of: pattern, with: "[spoiler] $1",
            options: .regularExpression
        )
        // Build HTML by splitting on ||content|| and escaping each part
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, escapeHTML(text))
        }
        let nsText = text as NSString
        var html = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            // Append escaped text before this match
            let before = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            html += escapeHTML(before)
            // Append spoiler span with escaped content
            let content = nsText.substring(with: match.range(at: 1))
            html += "<span data-mx-spoiler>\(escapeHTML(content))</span>"
            lastEnd = match.range.location + match.range.length
        }
        // Append remaining text after last match
        let remaining = nsText.substring(from: lastEnd)
        html += escapeHTML(remaining)
        return (plain, html)
    }

    private static func escapeHTML(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:  out.append(ch)
            }
        }
        return out
    }
}
