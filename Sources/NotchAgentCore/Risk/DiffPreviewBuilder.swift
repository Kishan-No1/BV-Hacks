// OWNER: workstream A (core-logic).
import Foundation

/// Builds the short diff preview shown in an edit request card.
public enum DiffPreviewBuilder {
    /// Lines shown per side for an edit.
    static let shownPerSide = 3
    /// Lines shown for a new file.
    static let shownForWrite = 4
    /// Characters per preview line.
    static let lineLimit = 120

    /// Edit: drops the common leading and trailing lines, counts the rest, shows up to 3 removed then 3 added.
    public static func edit(filePath: String, oldString: String, newString: String) -> DiffPreview {
        let h = hunk(old: oldString, new: newString)
        let lines = h.removed.prefix(shownPerSide).map { DiffLine(kind: .removed, text: cut($0)) }
            + h.added.prefix(shownPerSide).map { DiffLine(kind: .added, text: cut($0)) }
        return DiffPreview(fileName: LexicalPath.lastComponent(filePath), filePath: filePath,
                           added: h.added.count, removed: h.removed.count, lines: lines)
    }

    /// Write: every line of `content` is added; the first 4 are shown.
    public static func write(filePath: String, content: String) -> DiffPreview {
        let all = splitLines(content)
        return DiffPreview(fileName: LexicalPath.lastComponent(filePath), filePath: filePath,
                           added: all.count, removed: 0,
                           lines: all.prefix(shownForWrite).map { DiffLine(kind: .added, text: cut($0)) })
    }

    /// MultiEdit: counts summed over every edit, lines previewed from the first edit.
    public static func multiEdit(filePath: String, edits: [(old: String, new: String)]) -> DiffPreview {
        guard let first = edits.first else {
            return DiffPreview(fileName: LexicalPath.lastComponent(filePath), filePath: filePath, added: 0, removed: 0, lines: [])
        }
        var preview = edit(filePath: filePath, oldString: first.old, newString: first.new)
        for e in edits.dropFirst() {
            let h = hunk(old: e.old, new: e.new)
            preview.added += h.added.count
            preview.removed += h.removed.count
        }
        return preview
    }

    // MARK: Helpers

    /// "" has no lines; a single trailing newline does not add an empty line; "\r\n" counts as "\n".
    static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    static func hunk(old: String, new: String) -> (removed: [String], added: [String]) {
        let o = splitLines(old), n = splitLines(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(o.count, n.count) - prefix, o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        return (Array(o[prefix..<(o.count - suffix)]), Array(n[prefix..<(n.count - suffix)]))
    }

    static func cut(_ line: String) -> String { TextKit.shorten(line, to: lineLimit) }
}
