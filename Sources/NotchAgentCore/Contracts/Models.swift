// CONTRACT FILE - read-only for builders. Report problems in open_issues.
import Foundation

// MARK: - Risk

public enum RiskLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case low = 0, review = 1, high = 2

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    /// One step riskier, capped at `.high`.
    public var raised: RiskLevel { RiskLevel(rawValue: min(rawValue + 1, 2)) ?? .high }

    /// Pill text in the request card: "Low risk", "Review", "High risk".
    public var label: String {
        switch self {
        case .low: return "Low risk"
        case .review: return "Review"
        case .high: return "High risk"
        }
    }
}

public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case added, removed, context }
    public var kind: Kind
    /// Line text WITHOUT the leading "+" / "-" marker.
    public var text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// A short preview of an edit, for the request card's diff block.
public struct DiffPreview: Sendable, Equatable {
    public var fileName: String      // "session.ts"
    public var filePath: String      // absolute path from tool_input.file_path
    public var added: Int            // total added lines
    public var removed: Int          // total removed lines
    public var lines: [DiffLine]     // at most ~6 lines for display
    public var moreFiles: Int        // extra files in the same request (MultiEdit etc.), usually 0

    public init(fileName: String, filePath: String, added: Int, removed: Int, lines: [DiffLine], moreFiles: Int = 0) {
        self.fileName = fileName; self.filePath = filePath
        self.added = added; self.removed = removed
        self.lines = lines; self.moreFiles = moreFiles
    }

    /// "+12 −4" or "+12 −4 · and 1 more file".
    public var summary: String {
        var s = "+\(added) −\(removed)"
        if moreFiles > 0 { s += " · and \(moreFiles) more file\(moreFiles == 1 ? "" : "s")" }
        return s
    }
}

/// The plain-English risk read-out for one tool call. Advisory only: it never decides.
public struct Assessment: Sendable, Equatable {
    public var level: RiskLevel
    /// Plain English, no trailing period: "Run the test suite", "Edit session.ts", "Delete files outside this repo".
    /// May contain `backtick` spans, which the UI renders in monospace.
    public var title: String
    /// Short chips: "Read-only", "Inside repo", "Outside the project", "Not in git · can't undo".
    public var reasons: [String]
    /// The shell command to show in the `$ ...` card (Bash only).
    public var command: String?
    /// The diff to show (Edit / Write / MultiEdit / NotebookEdit).
    public var diff: DiffPreview?

    public init(level: RiskLevel, title: String, reasons: [String] = [], command: String? = nil, diff: DiffPreview? = nil) {
        self.level = level; self.title = title; self.reasons = reasons
        self.command = command; self.diff = diff
    }
}

// MARK: - Rules

/// A per-repo "always allow" rule the user created explicitly.
public struct Rule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Absolute path of the repo the rule applies to (git root when known, else the session cwd).
    public var repo: String
    /// Tool name: "Bash", "Edit", ...
    public var tool: String
    /// Bash only: the command must equal this or start with it followed by a space. nil = any call of `tool`.
    public var commandPrefix: String?
    public var createdAt: Date
    public var hitCount: Int

    public init(id: UUID = UUID(), repo: String, tool: String, commandPrefix: String? = nil, createdAt: Date = Date(), hitCount: Int = 0) {
        self.id = id; self.repo = repo; self.tool = tool
        self.commandPrefix = commandPrefix; self.createdAt = createdAt; self.hitCount = hitCount
    }
}

/// What "Always allow ... here" would create for a request. nil when no safe rule exists.
public struct RuleSuggestion: Sendable, Equatable {
    public var repo: String
    public var tool: String
    public var commandPrefix: String?
    /// Button text after "Always allow ": "npm test" (rendered in monospace) or "edits here".
    public var label: String

    public init(repo: String, tool: String, commandPrefix: String?, label: String) {
        self.repo = repo; self.tool = tool; self.commandPrefix = commandPrefix; self.label = label
    }

    public func makeRule(now: Date = Date()) -> Rule {
        Rule(repo: repo, tool: tool, commandPrefix: commandPrefix, createdAt: now)
    }
}

// MARK: - Sessions

public enum SessionStatus: String, Sendable, Equatable {
    case working    // orange dot
    case needsYou   // amber dot
    case done       // green dot
    case idle       // no dot
}

public struct Step: Identifiable, Sendable, Equatable {
    public var id: UUID
    /// "Read `src/auth/session.ts`", "Ran `npm test`". `backtick` spans render in monospace.
    public var text: String
    public var at: Date
    public var failed: Bool
    public init(id: UUID = UUID(), text: String, at: Date, failed: Bool = false) {
        self.id = id; self.text = text; self.at = at; self.failed = failed
    }
}

/// The tool call a session is running right now (drives the tool card and its live seconds counter).
public struct ToolActivity: Sendable, Equatable {
    public var toolName: String
    /// Tool-card label: a repo-relative path ("src/auth/session.ts") or a short command ("npm test").
    public var label: String
    public var startedAt: Date
    public var toolUseID: String?
    public init(toolName: String, label: String, startedAt: Date, toolUseID: String? = nil) {
        self.toolName = toolName; self.label = label; self.startedAt = startedAt; self.toolUseID = toolUseID
    }
}

public struct Session: Identifiable, Sendable, Equatable {
    public var id: String                 // session_id
    public var cwd: String
    public var name: String               // folder name of cwd
    public var branch: String?            // git branch, when readable
    public var title: String?             // Claude Code session_title, when set
    public var lastPrompt: String?        // last UserPromptSubmit prompt (first line, trimmed)
    public var status: SessionStatus {
        didSet { if status != .needsYou { attention = nil } }
    }
    /// What Claude is waiting on when it needs the user but notchAgent holds no request card
    /// (a question, a plan, Claude Code's own permission dialog). Cleared when the status moves on.
    public var attention: Attention?
    public var steps: [Step]             // completed steps of the current turn, oldest first
    public var currentStep: String?       // "Editing session.ts" while a tool runs
    public var currentTool: ToolActivity?
    public var turnStartedAt: Date?
    public var turnEndedAt: Date?
    public var editedFiles: [String]      // distinct file paths edited this turn
    public var lastEventAt: Date
    /// The Claude Code process running this session, when the hook reported it. The store drops the
    /// session once this process exits.
    public var process: ProcessIdentity?

    public init(id: String, cwd: String, name: String, branch: String? = nil, status: SessionStatus = .idle, lastEventAt: Date) {
        self.id = id; self.cwd = cwd; self.name = name; self.branch = branch
        self.status = status; self.steps = []; self.editedFiles = []; self.lastEventAt = lastEventAt
    }

    /// Text after "Claude ●" in the header: the last prompt, else the title, else the folder name.
    public var headline: String { lastPrompt ?? title ?? name }
}

/// Claude is waiting on the user in its own UI (notchAgent cannot answer it): the island pops a card for it.
public struct Attention: Sendable, Equatable {
    public enum Kind: String, Sendable { case question, plan, permission, input }
    public var kind: Kind
    /// One line, e.g. "Claude has a question".
    public var title: String
    /// The question, the start of the plan, or the notification text.
    public var detail: String
    /// Answer choices of a question, when it has them.
    public var options: [String]
    public var since: Date

    public init(kind: Kind, title: String, detail: String, options: [String] = [], since: Date) {
        self.kind = kind; self.title = title; self.detail = detail; self.options = options; self.since = since
    }

    /// For `AskUserQuestion` and `ExitPlanMode`, which notchAgent passes through to Claude Code's UI.
    public static func passThrough(toolName: String, input: JSONValue, at t: Date) -> Attention {
        if toolName == "ExitPlanMode" {
            let plan = input.string("plan").map(firstLines) ?? ""
            return Attention(kind: .plan, title: "Claude has a plan for you to approve",
                             detail: plan.isEmpty ? "Review the plan in Claude Code." : plan, since: t)
        }
        var detail = "Answer in Claude Code."
        var options: [String] = []
        if case .array(let questions)? = input["questions"], let q = questions.first {
            if let text = q.string("question") { detail = text }
            if case .array(let opts)? = q["options"] {
                options = opts.compactMap { $0.string("label") }
            }
            if questions.count > 1 { detail += "  (+\(questions.count - 1) more)" }
        }
        return Attention(kind: .question, title: "Claude has a question", detail: detail, options: options, since: t)
    }

    private static func firstLines(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.drop { "#*- ".contains($0) } }
            .map(String.init)
            .filter { !$0.isEmpty }
        return lines.prefix(2).joined(separator: " · ")
    }
}

/// A permission request waiting for the user. FIFO across sessions.
public struct PendingRequest: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var sessionID: String
    public var toolName: String
    public var toolInput: JSONValue
    public var cwd: String
    public var assessment: Assessment
    public var ruleSuggestion: RuleSuggestion?
    public var receivedAt: Date

    public init(id: UUID = UUID(), sessionID: String, toolName: String, toolInput: JSONValue, cwd: String,
                assessment: Assessment, ruleSuggestion: RuleSuggestion? = nil, receivedAt: Date) {
        self.id = id; self.sessionID = sessionID; self.toolName = toolName; self.toolInput = toolInput
        self.cwd = cwd; self.assessment = assessment; self.ruleSuggestion = ruleSuggestion; self.receivedAt = receivedAt
    }

    /// What ⌥↵ does: allow for low/review, deny for high.
    public var defaultDecision: Decision {
        assessment.level == .high ? .deny(message: nil) : .allow
    }

    /// High risk needs the 0.9 s press-and-hold to allow.
    public var requiresHoldToAllow: Bool { assessment.level == .high }
}

/// A short confirmation the island shows for ~1.1 s. The UI owns the dismissal timing.
public struct Toast: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case done, allowed, denied, autoAllowed }
    public var id: UUID
    public var kind: Kind
    public var sessionID: String
    public var at: Date
    public init(id: UUID = UUID(), kind: Kind, sessionID: String, at: Date) {
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.at = at
    }
}
