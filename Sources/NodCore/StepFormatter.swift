// OWNER: workstream A (core-logic). The public signatures below are FROZEN.
import Foundation

/// Turns tool calls into the short step lines shown in Progress.
/// Text may contain `backtick` spans; the UI renders them in monospace.
public enum StepFormatter {
    /// Commands are shortened to this many characters (ellipsis included).
    static let commandLimit = 48

    /// Past tense, for a finished tool call: "Read `src/auth/session.ts`", "Ran `npm test`",
    /// "Edited `session.ts`", "Searched “SessionError”".
    public static func completed(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        let input = toolInput
        switch toolName {
        case "Read", "NotebookRead":
            return displayPath(of: input, cwd: cwd).map { "Read \(TextKit.code($0))" } ?? "Read a file"
        case "Bash":
            return command(of: input).map { "Ran \(TextKit.code($0))" } ?? "Ran a command"
        case "Edit", "MultiEdit", "NotebookEdit":
            return fileName(of: input).map { "Edited \(TextKit.code($0))" } ?? "Edited a file"
        case "Write":
            return fileName(of: input).map { "Wrote \(TextKit.code($0))" } ?? "Wrote a file"
        case "Grep":
            return quoted(input.string("pattern")).map { "Searched \($0)" } ?? "Searched files"
        case "Glob":
            return pattern(of: input).map { "Listed \(TextKit.code($0))" } ?? "Listed files"
        case "LS":
            return displayPath(of: input, cwd: cwd, key: "path").map { "Listed \(TextKit.code($0))" } ?? "Listed files"
        case "WebFetch":
            return host(of: input).map { "Fetched \($0)" } ?? "Fetched a web page"
        case "WebSearch":
            return quoted(input.string("query")).map { "Searched the web for \($0)" } ?? "Searched the web"
        case "Agent", "Task":
            return description(of: input).map { "Ran a subagent: \($0)" } ?? "Ran a subagent"
        case "TodoWrite":
            return "Updated the to-do list"
        default:
            if let mcp = TextKit.mcpParts(toolName) { return "Used \(mcp.tool) (\(mcp.server))" }
            return "Used \(toolName.isEmpty ? "a tool" : toolName)"
        }
    }

    /// Present tense, for a running tool call: "Reading session.ts", "Running `npm test`", "Editing session.ts".
    public static func current(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        let input = toolInput
        switch toolName {
        case "Read", "NotebookRead":
            return fileName(of: input).map { "Reading \($0)" } ?? "Reading a file"
        case "Bash":
            return command(of: input).map { "Running \(TextKit.code($0))" } ?? "Running a command"
        case "Edit", "MultiEdit", "NotebookEdit":
            return fileName(of: input).map { "Editing \($0)" } ?? "Editing a file"
        case "Write":
            return fileName(of: input).map { "Writing \($0)" } ?? "Writing a file"
        case "Grep":
            return quoted(input.string("pattern")).map { "Searching \($0)" } ?? "Searching files"
        case "Glob":
            return pattern(of: input).map { "Listing \(TextKit.code($0))" } ?? "Listing files"
        case "LS":
            return displayPath(of: input, cwd: cwd, key: "path").map { "Listing \($0)" } ?? "Listing files"
        case "WebFetch":
            return host(of: input).map { "Fetching \($0)" } ?? "Fetching a web page"
        case "WebSearch":
            return quoted(input.string("query")).map { "Searching the web for \($0)" } ?? "Searching the web"
        case "Agent", "Task":
            return description(of: input).map { "Running a subagent: \($0)" } ?? "Running a subagent"
        case "TodoWrite":
            return "Updating the to-do list"
        default:
            if let mcp = TextKit.mcpParts(toolName) { return "Using \(mcp.tool) (\(mcp.server))" }
            return "Using \(toolName.isEmpty ? "a tool" : toolName)"
        }
    }

    /// Tool-card label: repo-relative path for file tools ("src/auth/session.ts"),
    /// the command for Bash (shortened to 48 chars), else the tool name.
    public static func toolLabel(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        switch toolName {
        case "Read", "NotebookRead", "Edit", "MultiEdit", "NotebookEdit", "Write":
            return displayPath(of: toolInput, cwd: cwd) ?? toolName
        case "Bash":
            return command(of: toolInput) ?? toolName
        default:
            if let mcp = TextKit.mcpParts(toolName) { return "\(mcp.tool) (\(mcp.server))" }
            return toolName.isEmpty ? "Tool" : toolName
        }
    }

    /// The first line of a user prompt, trimmed and shortened to `limit` characters with "…".
    public static func promptHeadline(_ prompt: String, limit: Int = 60) -> String {
        let first = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return TextKit.shorten(first, to: limit)
    }

    // MARK: - Helpers

    private static func rawPath(_ input: JSONValue, key: String? = nil) -> String? {
        let keys = key.map { [$0] } ?? ["file_path", "notebook_path", "path"]
        for k in keys { if let p = input.string(k), !p.isEmpty { return p } }
        return nil
    }

    /// Repo-relative inside `cwd`, the file name otherwise.
    private static func displayPath(of input: JSONValue, cwd: String, key: String? = nil) -> String? {
        guard let raw = rawPath(input, key: key) else { return nil }
        let root = LexicalPath.normalize(cwd)
        let path = LexicalPath.resolve(raw, base: root, home: NSHomeDirectory())
        if let rel = LexicalPath.relative(path, to: root) {
            return rel == "." ? LexicalPath.lastComponent(path) : rel
        }
        return LexicalPath.lastComponent(path)
    }

    private static func fileName(of input: JSONValue) -> String? {
        rawPath(input).map(LexicalPath.lastComponent)
    }

    private static func command(of input: JSONValue) -> String? {
        guard let c = input.string("command") else { return nil }
        let short = TextKit.shortCommand(c, limit: commandLimit)
        return short.isEmpty ? nil : short
    }

    private static func pattern(of input: JSONValue) -> String? {
        guard let p = input.string("pattern"), !p.isEmpty else { return nil }
        return TextKit.shorten(p, to: commandLimit)
    }

    private static func quoted(_ text: String?) -> String? {
        guard let text else { return nil }
        let t = TextKit.shorten(TextKit.collapseWhitespace(text), to: 40)
        return t.isEmpty ? nil : "“\(t)”"
    }

    private static func host(of input: JSONValue) -> String? {
        input.string("url").flatMap(TextKit.host(of:))
    }

    private static func description(of input: JSONValue) -> String? {
        let d = TextKit.sentence(input.string("description") ?? "", limit: 60)
        return d.isEmpty ? nil : d
    }
}
