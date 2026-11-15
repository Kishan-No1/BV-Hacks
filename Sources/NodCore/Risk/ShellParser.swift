// OWNER: workstream A (core-logic).
import Foundation

/// One simple command of a shell line: `cat a.txt > b.txt` -> words ["cat", "a.txt"], redirect (">", "b.txt").
struct ShellSegment: Equatable {
    struct Redirect: Equatable {
        /// ">", ">>", "&>", "<", "<<", "<<<", ...
        var op: String
        /// The file (or heredoc delimiter). nil for fd duplication like `2>&1`.
        var target: String?

        /// True when the redirect writes `target`.
        var writes: Bool { target != nil && op.contains(">") }
        /// True when `target` is a file the shell opens (not a heredoc delimiter or a here-string).
        var opensFile: Bool { target != nil && op != "<<" && op != "<<-" && op != "<<<" }
    }

    var words: [String] = []
    var redirects: [Redirect] = []
    /// Commands run inside `$(...)`, backticks, `<(...)` or `>(...)` within this segment.
    var substitutions: [[ShellSegment]] = []
    /// Segments joined by `|` share a pipeline number.
    var pipeline: Int = 0

    var isEmpty: Bool { words.isEmpty && redirects.isEmpty && substitutions.isEmpty }
}

/// A forgiving, quote-aware splitter for the shell commands Claude Code runs. It is a heuristic for the
/// risk read-out, not a shell: it never fails, and when unsure it errs towards seeing more commands.
enum ShellParser {
    /// Placeholder word for a command substitution.
    static let substitutionWord = "$(…)"

    static func parse(_ command: String) -> [ShellSegment] {
        var p = Parser(chars: Array(stripHeredocBodies(command)))
        return p.run()
    }

    // MARK: Heredocs

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// Removes heredoc bodies (`<<EOF ... EOF`) so text like a commit message is not read as commands.
    /// A body fed to a shell (`bash <<EOF`) is kept, because the shell runs it.
    static func stripHeredocBodies(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        var lines = command.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let delimiters = heredocDelimiters(in: lines[i])
            guard !delimiters.isEmpty else { i += 1; continue }
            let feedsShell = lineFeedsShell(lines[i])
            var j = i + 1
            var removed: [Int] = []
            for d in delimiters {
                var k = j
                while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces) != d { k += 1 }
                guard k < lines.count else { break }  // unterminated: keep everything (safer)
                removed.append(contentsOf: j...k)
                j = k + 1
            }
            if !feedsShell, !removed.isEmpty {
                for idx in removed.reversed() { lines.remove(at: idx) }
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func heredocDelimiters(in line: String) -> [String] {
        var out: [String] = []
        let chars = Array(line)
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "<", chars[i + 1] == "<", (i + 2 >= chars.count || chars[i + 2] != "<"),
               (i == 0 || chars[i - 1] != "<") {
                var k = i + 2
                if k < chars.count, chars[k] == "-" { k += 1 }
                while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                var word = ""
                var quote: Character? = nil
                if k < chars.count, chars[k] == "'" || chars[k] == "\"" { quote = chars[k]; k += 1 }
                while k < chars.count {
                    let c = chars[k]
                    if let q = quote { if c == q { break } }
                    else if c == " " || c == "\t" || c == ";" || c == "|" || c == "&" || c == ")" || c == "<" || c == ">" { break }
                    if c != "\\" { word.append(c) }
                    k += 1
                }
                if !word.isEmpty { out.append(word) }
                i = k
            } else {
                i += 1
            }
        }
        return out
    }

    private static func lineFeedsShell(_ line: String) -> Bool {
        guard let range = line.range(of: "<<") else { return false }
        let before = line[..<range.lowerBound]
        return before.split(whereSeparator: { " \t;|&(".contains($0) })
            .contains { shells.contains(LexicalPath.lastComponent(String($0))) }
    }

    // MARK: Parser

    private struct Parser {
        let chars: [Character]
        var i = 0
        var segments: [ShellSegment] = []
        var cur = ShellSegment()
        var word = ""
        var inWord = false
        var pendingRedirect: String?
        var pipeline = 0

        init(chars: [Character]) { self.chars = chars }

        private func peek(_ offset: Int = 1) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        mutating func endWord() {
            guard inWord else { return }
            if let op = pendingRedirect {
                cur.redirects.append(.init(op: op, target: word))
                pendingRedirect = nil
            } else {
                cur.words.append(word)
            }
            word = ""
            inWord = false
        }

        mutating func endSegment(newPipeline: Bool) {
            endWord()
            if let op = pendingRedirect {
                cur.redirects.append(.init(op: op, target: nil))
                pendingRedirect = nil
            }
            if !cur.isEmpty {
                cur.pipeline = pipeline
                segments.append(cur)
            }
            cur = ShellSegment()
            if newPipeline { pipeline += 1 }
        }

        /// Reads from `start` to the `)` that closes an already-open `(`. Returns the inner text and the
        /// index after the `)`.
        func readBalanced(from start: Int) -> (String, Int) {
            var depth = 1
            var j = start
            var inner = ""
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote {
                    if c == "\\" && q == "\"" && j + 1 < chars.count {
                        inner.append(c); inner.append(chars[j + 1]); j += 2; continue
                    }
                    if c == q { quote = nil }
                    inner.append(c); j += 1; continue
                }
                switch c {
                case "\\":
                    inner.append(c)
                    if j + 1 < chars.count { inner.append(chars[j + 1]); j += 2 } else { j += 1 }
                    continue
                case "'", "\"":
                    quote = c
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return (inner, j + 1) }
                default:
                    break
                }
                inner.append(c)
                j += 1
            }
            return (inner, j)
        }

        /// Reads a backtick substitution starting after the opening backtick.
        func readBackticks(from start: Int) -> (String, Int) {
            var j = start
            var inner = ""
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count { inner.append(chars[j + 1]); j += 2; continue }
                if c == "`" { return (inner, j + 1) }
                inner.append(c)
                j += 1
            }
            return (inner, j)
        }

        mutating func substitution(_ inner: String) {
            cur.substitutions.append(ShellParser.parse(inner))
            word += ShellParser.substitutionWord
            inWord = true
        }

        mutating func readRedirect() {
            // At "<" or ">" (or "&>" handled by the caller, which sets i past the "&").
            var op = String(chars[i])
            i += 1
            if op == ">" {
                if let n = peek(0), n == ">" || n == "|" { op.append(n); i += 1 }
            } else {
                if let n = peek(0), n == "<" {
                    op.append(n); i += 1
                    if let m = peek(0), m == "<" || m == "-" { op.append(m); i += 1 }
                } else if let n = peek(0), n == ">" {
                    op.append(n); i += 1
                }
            }
            if let n = peek(0), n == "&", op == ">" || op == "<" {
                op.append(n); i += 1
                // fd duplication: 2>&1, >&-, <&0
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "-" { j += 1 }
                if j > i {
                    cur.redirects.append(.init(op: op, target: nil))
                    i = j
                    return
                }
            }
            pendingRedirect = op
        }

        mutating func run() -> [ShellSegment] {
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "\\":
                    if let n = peek() {
                        if n != "\n" { word.append(n); inWord = true }
                        i += 2
                    } else {
                        i += 1
                    }
                case "'":
                    inWord = true
                    i += 1
                    while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                    i += 1
                case "\"":
                    inWord = true
                    i += 1
                    while i < chars.count, chars[i] != "\"" {
                        let d = chars[i]
                        if d == "\\", let n = peek(), "\"\\$`\n".contains(n) {
                            if n != "\n" { word.append(n) }
                            i += 2
                            continue
                        }
                        if d == "$", peek() == "(" {
                            let (inner, end) = readBalanced(from: i + 2)
                            substitution(inner)
                            i = end
                            continue
                        }
                        if d == "`" {
                            let (inner, end) = readBackticks(from: i + 1)
                            substitution(inner)
                            i = end
                            continue
                        }
                        word.append(d)
                        i += 1
                    }
                    i += 1
                case "`":
                    let (inner, end) = readBackticks(from: i + 1)
                    substitution(inner)
                    i = end
                case "$" where peek() == "(":
                    let (inner, end) = readBalanced(from: i + 2)
                    if inner.hasPrefix("("), inner.hasSuffix(")") {
                        word += "0"; inWord = true  // $(( arithmetic )) runs no command
                    } else {
                        substitution(inner)
                    }
                    i = end
                case "<" where peek() == "(", ">" where peek() == "(":
                    endWord()
                    let (inner, end) = readBalanced(from: i + 2)
                    substitution(inner)
                    i = end
                case " ", "\t", "\r":
                    endWord()
                    i += 1
                case "\n", ";":
                    endSegment(newPipeline: true)
                    i += 1
                case "&":
                    if peek() == "&" {
                        endSegment(newPipeline: true); i += 2
                    } else if peek() == ">" {
                        endWord()
                        i += 1  // now at ">"
                        readRedirect()
                        if let last = pendingRedirect { pendingRedirect = "&" + last }
                    } else {
                        endSegment(newPipeline: true); i += 1
                    }
                case "|":
                    if peek() == "|" {
                        endSegment(newPipeline: true); i += 2
                    } else {
                        endSegment(newPipeline: false); i += (peek() == "&" ? 2 : 1)
                    }
                case "(", ")":
                    endSegment(newPipeline: false)
                    i += 1
                case "#" where !inWord:
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                case ">", "<":
                    if inWord, !word.isEmpty, word.allSatisfy(\.isNumber), pendingRedirect == nil {
                        word = ""; inWord = false  // "2>file": the 2 is a file descriptor
                    } else {
                        endWord()
                    }
                    if let op = pendingRedirect {  // "> >" etc.: keep the first as target-less
                        cur.redirects.append(.init(op: op, target: nil)); pendingRedirect = nil
                    }
                    readRedirect()
                default:
                    word.append(c)
                    inWord = true
                    i += 1
                }
            }
            endSegment(newPipeline: true)
            return segments
        }
    }
}
