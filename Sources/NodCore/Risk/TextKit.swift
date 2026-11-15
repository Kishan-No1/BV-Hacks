// OWNER: workstream A (core-logic).
import Foundation

/// Small text helpers shared by RiskEngine and StepFormatter.
enum TextKit {
    /// Cuts `text` to at most `limit` characters, ending in "…" when it was cut.
    static func shorten(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        var head = String(text.prefix(limit - 1))
        while head.last == " " { head.removeLast() }
        return head + "…"
    }

    /// Joins all whitespace runs (newlines included) into single spaces and trims the ends.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Text safe to put inside a `backtick` span: backticks become a look-alike so the span never breaks.
    static func codeSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "ˋ")
    }

    /// `` `text` `` with the inner text made code-safe.
    static func code(_ text: String) -> String { "`" + codeSafe(text) + "`" }

    /// A one-line command for display: whitespace collapsed, cut to `limit`.
    static func shortCommand(_ command: String, limit: Int = 48) -> String {
        shorten(collapseWhitespace(command), to: limit)
    }

    /// The first non-empty line, trimmed, without a trailing period.
    static func sentence(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var t = line
        while t.hasSuffix(".") && !t.hasSuffix("...") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return shorten(t, to: limit)
    }

    /// `mcp__server__tool` -> ("server", "tool"). nil for other names.
    static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let rest = toolName.dropFirst(5)
        guard let sep = rest.range(of: "__") else { return nil }
        let server = String(rest[..<sep.lowerBound])
        let tool = String(rest[sep.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// The host of a URL string ("docs.example.com"), or nil.
    static func host(of url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let h = URLComponents(string: trimmed)?.host, !h.isEmpty { return h }
        // Scheme-less ("example.com/path"): try again with a scheme.
        if !trimmed.contains("://"), let h = URLComponents(string: "https://" + trimmed)?.host, !h.isEmpty,
           h.contains(".") {
            return h
        }
        return nil
    }
}
