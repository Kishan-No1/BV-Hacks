// OWNER: workstream A (core-logic). The public signatures below are FROZEN; bodies are placeholders.
import Foundation

/// Per-repo "always allow" rules, persisted as JSON. Thread-safe.
/// A missing or corrupt file means "no rules"; it must never crash or auto-allow.
public final class RulesStore: @unchecked Sendable {
    /// `~/Library/Application Support/Nod/rules.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Nod/rules.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var stored: [Rule] = []

    /// `fileURL: nil` keeps rules in memory only (tests, demo mode).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let rules = try? Self.decoder.decode([Rule].self, from: data) {
            stored = rules
        }
    }

    public var rules: [Rule] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// The rule that auto-allows this call, or nil. Must be conservative: a Bash command with shell
    /// operators (`;`, `&&`, `||`, `|`, backticks, `$(`, redirects) never matches a prefix rule.
    public func match(toolName: String, toolInput: JSONValue, cwd: String) -> Rule? {
        // SCAFFOLD PLACEHOLDER - exact cwd, no git-root resolution.
        lock.lock(); defer { lock.unlock() }
        return stored.first { rule in
            guard rule.repo == cwd, rule.tool == toolName else { return false }
            guard let prefix = rule.commandPrefix else { return true }
            guard let cmd = toolInput.string("command") else { return false }
            if cmd.contains(where: { ";&|`$><\n".contains($0) }) { return false }
            return cmd == prefix || cmd.hasPrefix(prefix + " ")
        }
    }

    /// What "Always allow ... here" would create. Returns nil for anything that must not get a rule
    /// (high-risk calls, commands with shell operators, sensitive paths).
    public func suggestion(toolName: String, toolInput: JSONValue, cwd: String, assessment: Assessment) -> RuleSuggestion? {
        // SCAFFOLD PLACEHOLDER
        guard assessment.level != .high, toolName == "Bash", let cmd = toolInput.string("command") else { return nil }
        if cmd.contains(where: { ";&|`$><\n".contains($0) }) { return nil }
        let prefix = cmd.split(separator: " ").prefix(2).joined(separator: " ")
        guard !prefix.isEmpty else { return nil }
        return RuleSuggestion(repo: cwd, tool: "Bash", commandPrefix: prefix, label: prefix)
    }

    /// Adds a rule (no-op when an equivalent rule exists) and persists. Returns the stored rule.
    @discardableResult
    public func add(_ rule: Rule) -> Rule {
        lock.lock()
        if let existing = stored.first(where: { $0.repo == rule.repo && $0.tool == rule.tool && $0.commandPrefix == rule.commandPrefix }) {
            lock.unlock(); return existing
        }
        stored.append(rule)
        lock.unlock()
        save()
        return rule
    }

    public func remove(id: UUID) {
        lock.lock(); stored.removeAll { $0.id == id }; lock.unlock()
        save()
    }

    /// Increments the rule's `hitCount` and persists.
    public func recordHit(id: UUID) {
        lock.lock()
        if let i = stored.firstIndex(where: { $0.id == id }) { stored[i].hitCount += 1 }
        lock.unlock()
        save()
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    private func save() {
        guard let fileURL else { return }
        let snapshot = rules
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }
}
