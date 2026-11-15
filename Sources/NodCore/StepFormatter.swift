// OWNER: workstream A (core-logic). The public signatures below are FROZEN; bodies are placeholders.
import Foundation

/// Turns tool calls into the short step lines shown in Progress.
/// Text may contain `backtick` spans; the UI renders them in monospace.
public enum StepFormatter {
    /// Past tense, for a finished tool call: "Read `src/auth/session.ts`", "Ran `npm test`",
    /// "Edited `session.ts`", "Searched “SessionError”".
    public static func completed(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        // SCAFFOLD PLACEHOLDER
        "Used \(toolName)"
    }

    /// Present tense, for a running tool call: "Reading session.ts", "Running `npm test`", "Editing session.ts".
    public static func current(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        // SCAFFOLD PLACEHOLDER
        "Using \(toolName)"
    }

    /// Tool-card label: repo-relative path for file tools ("src/auth/session.ts"),
    /// the command for Bash (shortened to ~48 chars), else the tool name.
    public static func toolLabel(toolName: String, toolInput: JSONValue, cwd: String) -> String {
        // SCAFFOLD PLACEHOLDER
        toolInput.string("file_path") ?? toolInput.string("command") ?? toolName
    }

    /// The first line of a user prompt, trimmed and shortened to `limit` characters with "…".
    public static func promptHeadline(_ prompt: String, limit: Int = 60) -> String {
        // SCAFFOLD PLACEHOLDER
        let first = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }
}
