// OWNER: workstream A (core-logic). The public signatures `init()` and `assess(toolName:toolInput:cwd:)` are FROZEN.
import Foundation

/// Pure advisory risk read-out. Never decides anything.
///
/// Rules (lexical only: no disk or network access):
/// - Read-only tools are low; a read outside `cwd` is review.
/// - Bash is split on `&&`, `||`, `;`, `|`, `&` and newlines outside quotes; every segment (and every `$(...)`)
///   is classified and the highest level wins. Paths outside `cwd` raise a segment one step.
/// - Edit tools are review inside `cwd`, high outside it, on a secrets file, or on a file that runs code
///   later (`.git/`, `.claude/`, `.mcp.json`).
/// - WebFetch, MCP and unknown tools are review.
/// - Low Bash titles may use Claude's own `description`, but only for a short command that the card shows
///   in full next to it; review and high titles always come from templates.
public struct RiskEngine: Sendable {
    /// Used to expand `~` and `$HOME`.
    let home: String

    public init() {
        self.init(homeDirectory: NSHomeDirectory())
    }

    /// `homeDirectory` expands `~` and `$HOME` (tests pass a fixed one).
    public init(homeDirectory: String) {
        home = LexicalPath.normalize(homeDirectory)
    }

    /// - Parameters:
    ///   - toolName: `tool_name` from the hook payload ("Bash", "Edit", "mcp__server__tool", ...).
    ///   - toolInput: `tool_input` from the hook payload.
    ///   - cwd: the session's working directory (absolute path); "" when unknown.
    public func assess(toolName: String, toolInput: JSONValue, cwd: String) -> Assessment {
        analyze(toolName: toolName, toolInput: toolInput, cwd: cwd).assessment
    }

    /// The assessment plus the facts RulesStore needs to stay conservative.
    struct Analysis {
        var assessment: Assessment
        /// Some path the call touches lies outside `cwd`.
        var touchesOutside: Bool
        /// Some path the call touches is a secrets file.
        var touchesSensitive: Bool
    }

    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebSearch", "TodoWrite", "NotebookRead"]
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    func analyze(toolName: String, toolInput: JSONValue, cwd: String) -> Analysis {
        let root = LexicalPath.normalize(cwd)
        if toolName == "Bash" { return bash(toolInput, root: root) }
        if Self.editTools.contains(toolName) { return edit(toolName, toolInput, root: root) }
        if Self.readOnlyTools.contains(toolName) { return readOnly(toolName, toolInput, root: root) }
        if toolName == "WebFetch" {
            let host = TextKit.host(of: toolInput.string("url") ?? "")
            return Analysis(assessment: Assessment(level: .review, title: host.map { "Fetch \($0)" } ?? "Fetch a web page",
                                                   reasons: [Reason.network]),
                            touchesOutside: false, touchesSensitive: false)
        }
        if let mcp = TextKit.mcpParts(toolName) {
            return Analysis(assessment: Assessment(level: .review, title: "Use \(mcp.tool) (\(mcp.server))", reasons: ["MCP tool"]),
                            touchesOutside: false, touchesSensitive: false)
        }
        let name = toolName.isEmpty ? "a tool" : toolName
        return Analysis(assessment: Assessment(level: .review, title: "Use \(name)", reasons: [Reason.unfamiliarTool]),
                        touchesOutside: false, touchesSensitive: false)
    }

    // MARK: - Bash

    private func bash(_ input: JSONValue, root: String) -> Analysis {
        let command = input.string("command") ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Analysis(assessment: Assessment(level: .review, title: "Run a shell command", reasons: [], command: command),
                            touchesOutside: false, touchesSensitive: false)
        }
        let v = BashClassifier(root: root, home: home).classify(command)
        let generic = "Run \(TextKit.code(TextKit.shortCommand(command)))"
        let title: String
        if v.level == .low, Self.showsInFull(command) {
            // Claude's own summary is only used when the command is low risk anyway AND short enough that
            // the `$ command` card under the title shows all of it; otherwise the title is the command.
            let description = TextKit.sentence(input.string("description") ?? "", limit: 60)
            title = description.isEmpty ? generic : description
        } else {
            title = v.title ?? generic
        }
        return Analysis(assessment: Assessment(level: v.level, title: title, reasons: v.reasons, command: command),
                        touchesOutside: v.outside, touchesSensitive: v.sensitive)
    }

    /// The request card shows one line of the command; longer or multi-line commands get cut off.
    static let fullCommandLimit = 64

    static func showsInFull(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count <= fullCommandLimit && !c.contains(where: \.isNewline)
    }

    // MARK: - Edit tools

    private func edit(_ tool: String, _ input: JSONValue, root: String) -> Analysis {
        let raw = input.string("file_path") ?? input.string("notebook_path") ?? ""
        let verb = tool == "Write" ? "Write" : "Edit"
        guard !raw.isEmpty else {
            return Analysis(assessment: Assessment(level: .review, title: "\(verb) a file", reasons: []),
                            touchesOutside: false, touchesSensitive: false)
        }
        let path = LexicalPath.resolve(raw, base: root, home: home)
        let outside = !root.isEmpty && path.hasPrefix("/") && !LexicalPath.isInside(path, root: root)
        let sensitive = LexicalPath.isSensitive(path)
        let codeConfig = LexicalPath.isCodeConfig(path)

        let diff: DiffPreview
        switch tool {
        case "Write":
            diff = DiffPreviewBuilder.write(filePath: raw, content: input.string("content") ?? "")
        case "MultiEdit":
            var edits = (input["edits"]?.arrayValue ?? []).map { ($0.string("old_string") ?? "", $0.string("new_string") ?? "") }
            if edits.isEmpty, input.string("old_string") != nil || input.string("new_string") != nil {
                edits = [(input.string("old_string") ?? "", input.string("new_string") ?? "")]
            }
            diff = DiffPreviewBuilder.multiEdit(filePath: raw, edits: edits.map { (old: $0.0, new: $0.1) })
        case "NotebookEdit":
            if input.string("edit_mode") == "delete" {
                diff = DiffPreview(fileName: LexicalPath.lastComponent(raw), filePath: raw, added: 0, removed: 0, lines: [])
            } else {
                diff = DiffPreviewBuilder.write(filePath: raw, content: input.string("new_source") ?? "")
            }
        default:
            diff = DiffPreviewBuilder.edit(filePath: raw, oldString: input.string("old_string") ?? "",
                                           newString: input.string("new_string") ?? "")
        }

        var level: RiskLevel = .review
        var reasons: [String] = []
        if outside { level = .high; reasons.append(Reason.outside) }
        if sensitive { level = .high; reasons.append(Reason.secrets) }
        if codeConfig, !sensitive { level = .high; reasons.append(Reason.runsCodeLater) }
        if !outside, !sensitive, !codeConfig, !root.isEmpty { reasons.append(Reason.inside) }
        return Analysis(assessment: Assessment(level: level, title: "\(verb) \(LexicalPath.lastComponent(path))",
                                               reasons: reasons, diff: diff),
                        touchesOutside: outside, touchesSensitive: sensitive || codeConfig)
    }

    // MARK: - Read-only tools

    private func readOnly(_ tool: String, _ input: JSONValue, root: String) -> Analysis {
        var raw: [String] = []
        switch tool {
        case "Read": raw = [input.string("file_path")].compactMap { $0 }
        case "NotebookRead": raw = [input.string("notebook_path")].compactMap { $0 }
        case "Grep", "LS": raw = [input.string("path")].compactMap { $0 }
        case "Glob":
            raw = [input.string("path")].compactMap { $0 }
            if let p = input.string("pattern"), p.hasPrefix("/") || p.hasPrefix("~") { raw.append(p) }
        default: break
        }
        let resolved = raw.filter { !$0.isEmpty }.map { LexicalPath.resolve($0, base: root, home: home) }
        let outside = !root.isEmpty && resolved.contains { $0.hasPrefix("/") && !LexicalPath.isInside($0, root: root) }
        let sensitive = resolved.contains(where: LexicalPath.isSensitive)

        var level: RiskLevel = .low
        var reasons = [Reason.readOnly]
        if sensitive { level = level.raised; reasons.append(Reason.secrets) }
        if outside { level = level.raised; reasons.insert(Reason.outside, at: 0) }
        return Analysis(assessment: Assessment(level: level, title: readOnlyTitle(tool, input, root: root), reasons: reasons),
                        touchesOutside: outside, touchesSensitive: sensitive)
    }

    private func readOnlyTitle(_ tool: String, _ input: JSONValue, root: String) -> String {
        func shown(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let p = LexicalPath.resolve(raw, base: root, home: home)
            return LexicalPath.relative(p, to: root) ?? LexicalPath.abbreviated(p, home: home)
        }
        switch tool {
        case "Read":
            return shown(input.string("file_path")).map { "Read \(TextKit.code($0))" } ?? "Read a file"
        case "NotebookRead":
            return shown(input.string("notebook_path")).map { "Read \(TextKit.code($0))" } ?? "Read a notebook"
        case "Grep":
            guard let p = input.string("pattern"), !p.isEmpty else { return "Search files" }
            return "Search for “\(TextKit.shorten(TextKit.collapseWhitespace(p), to: 40))”"
        case "Glob":
            guard let p = input.string("pattern"), !p.isEmpty else { return "List files" }
            return "List \(TextKit.code(TextKit.shorten(p, to: 48)))"
        case "LS":
            return shown(input.string("path")).map { "List \(TextKit.code($0))" } ?? "List files"
        case "WebSearch":
            guard let q = input.string("query"), !q.isEmpty else { return "Search the web" }
            return "Search the web for “\(TextKit.shorten(TextKit.collapseWhitespace(q), to: 48))”"
        case "TodoWrite":
            return "Update the to-do list"
        default:
            return "Use \(tool)"
        }
    }
}
