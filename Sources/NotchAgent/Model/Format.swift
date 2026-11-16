// OWNER: workstream C (app-ui).
import Foundation
import NotchAgentCore

/// Text helpers for the island. Pure, unit-tested.
enum Format {
    /// "42s", "9m 12s", "1h 3m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// The tool card's live counter: "12.50 seconds".
    static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.2f seconds", max(0, t))
    }

    static func filesChanged(_ n: Int) -> String {
        switch n {
        case 0: return "No files changed"
        case 1: return "1 file changed"
        default: return "\(n) files changed"
        }
    }

    /// "3 files changed · 9m 12s" for the green Finished card.
    static func finishedSummary(_ s: Session) -> String {
        var out = filesChanged(s.editedFiles.count)
        if let start = s.turnStartedAt, let end = s.turnEndedAt {
            out += " · " + duration(end.timeIntervalSince(start))
        }
        return out
    }

    /// The tool card bar: prototype `Math.min(92, 18 + t * 2.4)` percent.
    static func toolBarFraction(elapsed t: TimeInterval) -> Double {
        min(0.92, 0.18 + max(0, t) * 0.024)
    }

    /// The text for a request card that has neither a command nor a diff (WebFetch, MCP tools, ...).
    static func requestDetail(toolName: String, input: JSONValue) -> String {
        for key in ["url", "query", "file_path", "notebook_path", "path", "pattern", "description"] {
            if let v = input.string(key), !v.isEmpty { return v }
        }
        return toolName
    }

    /// First line of a shell command; " …" marks that more lines follow.
    static func commandLine(_ command: String) -> String {
        let lines = command.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        guard let first = lines.first else { return command }
        return lines.count > 1 ? String(first) + " …" : String(first)
    }
}

/// Splits text with `backtick` spans into plain and code segments (the prototype's `<code>`).
enum InlineCode {
    struct Segment: Equatable {
        var text: String
        var isCode: Bool
    }

    static func segments(_ s: String) -> [Segment] {
        guard !s.isEmpty else { return [] }
        let parts = s.components(separatedBy: "`")
        var out: [Segment] = []
        // An even number of parts means an odd number of backticks: the last one is unmatched.
        let unmatched = parts.count % 2 == 0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            if unmatched && isLast {
                out.append(Segment(text: "`" + part, isCode: false))
            } else if !part.isEmpty {
                out.append(Segment(text: part, isCode: i % 2 == 1))
            }
        }
        // Merge adjacent plain segments.
        var merged: [Segment] = []
        for seg in out {
            if let last = merged.last, !last.isCode, !seg.isCode {
                merged[merged.count - 1].text += seg.text
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    static func plain(_ s: String) -> String {
        segments(s).map(\.text).joined()
    }
}
