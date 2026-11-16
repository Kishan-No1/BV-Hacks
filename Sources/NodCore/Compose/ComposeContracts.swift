// CONTRACT FILE for the prompt composer (polish, learned style, tmux send).
// Shared types and protocols only. Implementations live next to this file:
//   StyleLearner.swift, StyleProfileStore.swift      learned style profile (local, deterministic)
//   PolishService.swift, RepoContext.swift, APIKeyProvider.swift   the one network call
//   TmuxSender.swift                                 sending text to a Claude Code pane
// Privacy rule for everything in this folder: never log, print or put into an error the API key,
// the prompt text, the polished text or the style notes. Errors carry status codes and types only.
import Foundation

// MARK: - Learned style profile

/// One short, inspectable style note, e.g. "Add: “run tests after edits”".
public struct StyleNote: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity: "length.shorter", "length.longer", "format.sentences", "format.bullets",
    /// "add:<normalized line>", "omit:<normalized line>", "omit-word:<phrase>", "verb:<from>><to>", "verbs.top".
    public var key: String
    /// The natural-language note that is injected into the polish request and shown in the chip.
    public var text: String
    /// Net evidence for the note. A note is active once this reaches its activation threshold.
    public var score: Int
    /// How many outcomes supported the note (first sighting included).
    public var count: Int
    /// Consecutive outcomes in which the user removed what the note asks for. Two drops the note.
    public var strikes: Int
    /// Only active notes are injected and shown.
    public var active: Bool
    public var updatedAt: Date

    public var id: String { key }

    public init(key: String, text: String, score: Int = 0, count: Int = 0, strikes: Int = 0, active: Bool = false,
                updatedAt: Date) {
        self.key = key; self.text = text; self.score = score; self.count = count
        self.strikes = strikes; self.active = active; self.updatedAt = updatedAt
    }
}

/// What the user did with one prompt: the rough text, what the polish returned, and what was actually sent.
public struct StyleOutcome: Codable, Equatable, Sendable {
    public var raw: String
    /// nil when the prompt was sent without a polish (polish off, no key, or the call failed).
    public var polished: String?
    public var final: String
    public var at: Date

    public init(raw: String, polished: String?, final: String, at: Date) {
        self.raw = raw; self.polished = polished; self.final = final; self.at = at
    }
}

public enum StyleChange: Equatable, Sendable {
    case learned(StyleNote)
    case reinforced(StyleNote)
    case dropped(StyleNote)

    public var note: StyleNote {
        switch self {
        case .learned(let n), .reinforced(let n), .dropped(let n): return n
        }
    }

    /// The one-line chip: "Learned: …" or "Dropped: …". nil for a reinforcement (nothing new to show).
    public var chipText: String? {
        switch self {
        case .learned(let n): return "Learned: \(n.text)"
        case .dropped(let n): return "Dropped: \(n.text)"
        case .reinforced: return nil
        }
    }
}

/// The whole local profile, stored as JSON in `~/Library/Application Support/Nod/style.json`.
public struct StyleProfile: Codable, Equatable, Sendable {
    public static let maxOutcomes = 50

    public var version: Int
    public var notes: [StyleNote]
    /// The last `maxOutcomes` outcomes, oldest first.
    public var outcomes: [StyleOutcome]
    /// How often a normalized polished line was removed by the user.
    public var removedCounts: [String: Int]
    /// How often a leading verb opened a line of a sent prompt.
    public var verbCounts: [String: Int]

    public init(version: Int = 1, notes: [StyleNote] = [], outcomes: [StyleOutcome] = [],
                removedCounts: [String: Int] = [:], verbCounts: [String: Int] = [:]) {
        self.version = version; self.notes = notes; self.outcomes = outcomes
        self.removedCounts = removedCounts; self.verbCounts = verbCounts
    }

    public static let empty = StyleProfile()

    /// The active notes to inject into the next polish request: highest count first, then most recent, then key.
    public func topNotes(limit: Int = 8) -> [StyleNote] {
        let sorted = notes.filter(\.active).sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.key < b.key
        }
        return Array(sorted.prefix(max(0, limit)))
    }
}

// MARK: - Polish (the only network call)

/// Repo facts gathered locally for the polish request. Names only: never file contents.
public struct RepoContext: Equatable, Sendable {
    /// The session directory with the home directory abbreviated to "~".
    public var cwd: String
    public var branch: String?
    /// Subjects of the last 3 commits, newest first.
    public var commitSubjects: [String]
    /// File names from `git status --porcelain`, capped.
    public var changedFiles: [String]

    public init(cwd: String, branch: String? = nil, commitSubjects: [String] = [], changedFiles: [String] = []) {
        self.cwd = cwd; self.branch = branch; self.commitSubjects = commitSubjects; self.changedFiles = changedFiles
    }
}

public protocol RepoContextProviding: Sendable {
    func context(cwd: String) async -> RepoContext
}

/// Everything that goes to the API for one polish: the rough prompt, the style notes, the repo context.
public struct PolishRequest: Equatable, Sendable {
    public var raw: String
    public var notes: [String]
    public var context: RepoContext?

    public init(raw: String, notes: [String] = [], context: RepoContext? = nil) {
        self.raw = raw; self.notes = notes; self.context = context
    }
}

public enum PolishError: Error, Equatable, Sendable {
    /// No ANTHROPIC_API_KEY in the environment and no key in the Keychain.
    case noKey
    /// The API answered with an error status. `type` is the API's error type ("authentication_error"), never a body.
    case http(status: Int, type: String?)
    /// The request did not complete (offline, timeout).
    case network
    /// The model declined (`stop_reason: "refusal"`).
    case refused
    /// The response had no text.
    case empty

    /// One line for the composer's error state.
    public var userMessage: String {
        switch self {
        case .noKey: return "No Anthropic API key. Set one in the Nod menu, or send the text as written."
        case .http(let status, _) where status == 401 || status == 403: return "The Anthropic API key was rejected (\(status))."
        case .http(let status, _) where status == 429 || status >= 500: return "Anthropic is busy (\(status)). Try again, or send the text as written."
        case .http(let status, let type): return "Polish failed (\(status)\(type.map { " \($0)" } ?? ""))."
        case .network: return "Could not reach Anthropic. Send the text as written, or try again."
        case .refused: return "The model declined to rewrite this. Send the text as written."
        case .empty: return "The polish came back empty. Send the text as written, or try again."
        }
    }
}

public protocol Polishing: Sendable {
    func polish(_ request: PolishRequest) async -> Result<String, PolishError>
}

// MARK: - Send (tmux)

public enum SendResult: Equatable, Sendable {
    /// The text was typed into the pane and Enter was pressed.
    case sent(pane: String)
    case tmuxMissing
    /// No pane is recorded for this session (it was not started with scripts/nod-claude), or the pane is gone.
    case paneNotFound
    /// The pane is not showing Claude Code's input prompt (for example a permission dialog is open).
    case notAtPrompt
    /// tmux ran and failed. The string is a short reason without the prompt text.
    case failed(String)

    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    /// One line for the composer when the send did not happen. nil when sent.
    public var userMessage: String? {
        switch self {
        case .sent: return nil
        case .tmuxMissing: return "tmux is not installed. Copy the prompt and paste it into the session."
        case .paneNotFound: return "No tmux pane for this session. Start it with scripts/nod-claude, or copy the prompt."
        case .notAtPrompt: return "That session is not at its prompt. Copy the prompt, or try again when it is."
        case .failed(let reason): return "tmux could not send the prompt (\(reason)). Copy it instead."
        }
    }
}

public protocol PromptSending: Sendable {
    /// Types `text` into the Claude Code session's tmux pane and presses Enter. Never called without an
    /// explicit Send from the user.
    func send(text: String, sessionID: String, cwd: String) async -> SendResult
}
