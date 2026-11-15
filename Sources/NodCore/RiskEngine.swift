// OWNER: workstream A (core-logic). The public signatures below are FROZEN; bodies are placeholders.
import Foundation

/// Pure advisory risk read-out. Never decides anything.
public struct RiskEngine: Sendable {
    public init() {}

    /// - Parameters:
    ///   - toolName: `tool_name` from the hook payload ("Bash", "Edit", "mcp__server__tool", ...).
    ///   - toolInput: `tool_input` from the hook payload.
    ///   - cwd: the session's working directory (absolute path); "" when unknown.
    public func assess(toolName: String, toolInput: JSONValue, cwd: String) -> Assessment {
        // SCAFFOLD PLACEHOLDER - workstream A replaces this with the real rules.
        switch toolName {
        case "Read", "Grep", "Glob", "LS", "WebSearch":
            return Assessment(level: .low, title: "Use \(toolName)", reasons: ["Read-only"])
        case "Bash":
            let cmd = toolInput.string("command") ?? ""
            return Assessment(level: .review, title: "Run `\(cmd)`", reasons: [], command: cmd)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = toolInput.string("file_path") ?? toolInput.string("notebook_path") ?? ""
            let name = (path as NSString).lastPathComponent
            var lines: [DiffLine] = []
            if let old = toolInput.string("old_string") { lines.append(DiffLine(kind: .removed, text: old)) }
            if let new = toolInput.string("new_string") ?? toolInput.string("content") { lines.append(DiffLine(kind: .added, text: new)) }
            let diff = DiffPreview(fileName: name, filePath: path,
                                   added: lines.filter { $0.kind == .added }.count,
                                   removed: lines.filter { $0.kind == .removed }.count, lines: lines)
            return Assessment(level: .review, title: "Edit \(name)", reasons: [], diff: diff)
        default:
            return Assessment(level: .review, title: "Use \(toolName)", reasons: [])
        }
    }
}
