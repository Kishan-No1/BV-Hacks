// OWNER: workstream A (core-logic). The public signatures below are FROZEN; extra API is additive.
import Foundation

/// Per-repo "always allow" rules, persisted as JSON. Thread-safe.
/// A missing or corrupt file means "no rules"; it must never crash or auto-allow.
///
/// Matching is deliberately conservative. On top of the rule itself it refuses:
/// - Bash commands with shell operators (`;`, `&`, `|`, backtick, `$`, `<`, `>`, newline) for prefix rules,
/// - calls the RiskEngine rates high,
/// - calls that touch a path outside the session cwd, a secrets file, or a file that runs code later
///   (`.git/`, `.claude/`, `.mcp.json`),
/// - for prefix rules, a command the RiskEngine rates higher than the bare prefix (a `sort` rule never
///   allows `sort -o file`), any argument containing `=`, any option that is not a plain `-abc` /
///   `--long-name` word, and, when the prefix itself is review level, any option outside a short
///   per-command allowlist.
public final class RulesStore: @unchecked Sendable {
    /// `~/Library/Application Support/notchAgent/rules.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("notchAgent/rules.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var stored: [Rule] = []
    private var rootCache: [String: String] = [:]
    private let engine = RiskEngine()

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

    /// Rules for one repo (the repo identity of `cwd`), oldest first. For the Rules tab.
    public func rules(forCwd cwd: String) -> [Rule] {
        let repo = repoRoot(cwd)
        lock.lock(); defer { lock.unlock() }
        return stored.filter { $0.repo == repo }
    }

    /// The rule that auto-allows this call, or nil. Must be conservative: a Bash command with shell
    /// operators (`;`, `&&`, `||`, `|`, backticks, `$(`, redirects) never matches a prefix rule.
    public func match(toolName: String, toolInput: JSONValue, cwd: String) -> Rule? {
        let repo = repoRoot(cwd)
        guard !repo.isEmpty else { return nil }
        let candidates: [Rule] = {
            lock.lock(); defer { lock.unlock() }
            return stored.filter { $0.repo == repo && $0.tool == toolName }
        }()
        guard !candidates.isEmpty else { return nil }

        // Never auto-allow what the risk engine rates high or what leaves the project.
        let analysis = engine.analyze(toolName: toolName, toolInput: toolInput, cwd: cwd)
        if analysis.assessment.level == .high || analysis.touchesOutside || analysis.touchesSensitive { return nil }

        let command = toolInput.string("command").map(Self.normalizedCommand)
        return candidates.first { rule in
            guard let prefix = rule.commandPrefix else { return true }
            guard let command, !command.isEmpty, !Self.hasShellOperators(command) else { return false }
            let p = Self.normalizedCommand(prefix)
            guard !p.isEmpty else { return false }
            guard command == p || command.hasPrefix(p + " ") else { return false }
            // A stored prefix that would no longer be offered (sed, awk, rg, ...) no longer matches.
            guard Self.bashPrefix(p) == p else { return false }
            // The rule covers the prefix at its own risk level, not riskier variants of it.
            let prefixLevel = engine.assess(toolName: toolName, toolInput: ["command": .string(p)], cwd: cwd).level
            guard analysis.assessment.level <= prefixLevel else { return false }
            let rest = command.dropFirst(p.count).split(separator: " ").map(String.init)
            return Self.argumentsAreSafe(rest, prefix: p, strict: prefixLevel != .low)
        }
    }

    /// What "Always allow ... here" would create. Returns nil for anything that must not get a rule
    /// (high-risk calls, commands with shell operators, sensitive paths).
    public func suggestion(toolName: String, toolInput: JSONValue, cwd: String, assessment: Assessment) -> RuleSuggestion? {
        guard assessment.level != .high else { return nil }
        let repo = repoRoot(cwd)
        guard !repo.isEmpty else { return nil }
        let analysis = engine.analyze(toolName: toolName, toolInput: toolInput, cwd: cwd)
        if analysis.assessment.level == .high || analysis.touchesOutside || analysis.touchesSensitive { return nil }

        if toolName == "Bash" {
            guard let raw = toolInput.string("command") else { return nil }
            let command = Self.normalizedCommand(raw)
            guard !command.isEmpty, !Self.hasShellOperators(command), let prefix = Self.bashPrefix(command) else { return nil }
            return RuleSuggestion(repo: repo, tool: "Bash", commandPrefix: prefix, label: prefix)
        }
        if RiskEngine.editTools.contains(toolName) {
            return RuleSuggestion(repo: repo, tool: toolName, commandPrefix: nil, label: "edits here")
        }
        return nil
    }

    /// Adds a rule (no-op when an equivalent rule exists) and persists. Returns the stored rule.
    @discardableResult
    public func add(_ rule: Rule) -> Rule {
        var rule = rule
        rule.repo = LexicalPath.normalize(rule.repo)
        if let p = rule.commandPrefix { rule.commandPrefix = Self.normalizedCommand(p) }
        lock.lock(); defer { lock.unlock() }
        if let existing = stored.first(where: { $0.repo == rule.repo && $0.tool == rule.tool && $0.commandPrefix == rule.commandPrefix }) {
            return existing
        }
        stored.append(rule)
        saveLocked()
        return rule
    }

    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let before = stored.count
        stored.removeAll { $0.id == id }
        if stored.count != before { saveLocked() }
    }

    /// Increments the rule's `hitCount` and persists.
    public func recordHit(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let i = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[i].hitCount += 1
        saveLocked()
    }

    // MARK: - Repo identity

    /// The nearest ancestor of `cwd` (itself included) that contains `.git` (file or directory), else `cwd`.
    /// Both normalized lexically. "" for "".
    public static func repoRoot(for cwd: String) -> String {
        let start = LexicalPath.normalize(cwd)
        guard start.hasPrefix("/") else { return start }
        let fm = FileManager.default
        var dir = start
        while true {
            if fm.fileExists(atPath: dir == "/" ? "/.git" : dir + "/.git") { return dir }
            if dir == "/" { return start }
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty { return start }
        }
    }

    private func repoRoot(_ cwd: String) -> String {
        lock.lock()
        if let hit = rootCache[cwd] { lock.unlock(); return hit }
        lock.unlock()
        let root = Self.repoRoot(for: cwd)
        lock.lock(); rootCache[cwd] = root; lock.unlock()
        return root
    }

    // MARK: - Bash prefixes

    /// Whitespace runs collapsed to one space, ends trimmed.
    static func normalizedCommand(_ command: String) -> String {
        command.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// `;`, `&`, `|`, backtick, `$`, `<`, `>`, `(`, `)`, newline or carriage return anywhere (quoted or not).
    static func hasShellOperators(_ command: String) -> Bool {
        command.contains { ";&|`$<>()\n\r".contains($0) }
    }

    /// Tools whose second word is a subcommand that belongs in the prefix.
    private static let subcommandTools: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "git", "swift", "cargo", "go", "make", "gmake", "docker", "kubectl", "brew",
        "pip", "pip3", "uv", "poetry", "bundle", "rails", "rake", "mix", "dotnet", "gradle", "./gradlew", "mvn",
        "terraform", "gh", "deno", "pod", "flutter", "dart", "xcrun", "composer", "gem", "pnpx", "npx", "bunx",
    ]
    /// Subcommands that run arbitrary scripts or packages, so the prefix needs the next word too.
    private static let runSubcommands: Set<String> = ["run", "run-script", "exec", "x", "dlx"]
    /// Tools with command groups (`docker compose up`, `gh pr view`): the prefix needs three words.
    private static let groupedTools: Set<String> = ["docker", "gh", "aws", "gcloud", "az", "kubectl"]

    /// Options a review-level prefix rule still auto-allows. Every other option falls back to asking.
    private static let reviewOptionAllowlist: [String: Set<String>] = [
        "git commit": ["-m", "-a", "-am", "--all", "--message", "-q", "--quiet"],
        "git add": ["-A", "--all", "-u", "--update", "-v"],
        "mkdir": ["-p", "-v"],
        "cp": ["-r", "-R", "-a", "-p", "-v", "-n"],
        "mv": ["-v", "-n"],
        "ln": ["-s"],
    ]

    /// The words after a rule's prefix. Refuses anything containing `=` (`--output=FILE`, `SHELL=./x`,
    /// `--script-shell=./x`) and any option that is not a plain `-abc` or `--long-name` word
    /// (`-O'rm -rf ~'`). `strict` (the prefix itself is review level) allows only the options in
    /// `reviewOptionAllowlist`; a lone `--` is always fine.
    static func argumentsAreSafe(_ rest: [String], prefix: String, strict: Bool) -> Bool {
        let allowed = reviewOptionAllowlist[prefix] ?? []
        for word in rest {
            if word == "--" { continue }
            if word.contains("=") { return false }
            let bare = word.drop { $0 == "\"" || $0 == "'" || $0 == "\\" }
            guard bare.hasPrefix("-") else { continue }
            if strict {
                guard allowed.contains(word) else { return false }
            } else {
                let body = word.drop { $0 == "-" }
                let dashes = word.count - body.count
                guard dashes <= 2, !body.isEmpty,
                      body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || (dashes == 2 && $0 == "-")) })
                else { return false }
            }
        }
        return true
    }

    /// Never offered as a prefix: interpreters, privilege, deletion, network fetches, and tools whose
    /// arguments are programs of their own (sed, awk) or can name a program to run (rg --pre).
    private static let blockedFirstWords: Set<String> = [
        "sed", "gsed", "awk", "gawk", "mawk", "nawk", "rg",
        "rm", "sudo", "doas", "su", "curl", "wget", "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python2",
        "python3", "node", "ruby", "perl", "php", "osascript", "eval", "exec", "source", ".", "env", "xargs", "nohup",
        "time", "command", "builtin", "dd", "mkfs", "chmod", "chown", "chgrp", "ssh", "scp", "nc", "find", "deno",
        "lua", "Rscript", "timeout", "nice", "open", "kill", "killall", "pkill", "shred", "srm", "trash",
    ]
    private static let blockedPrefixes: Set<String> = [
        "git push", "git reset", "git clean", "git filter-branch", "git rebase", "npm publish", "pnpm publish",
        "yarn publish", "cargo publish", "gem push", "bun publish", "docker run", "docker exec", "docker rm",
        "docker rmi", "docker system", "docker volume", "kubectl delete", "kubectl apply", "kubectl exec",
        "terraform apply", "terraform destroy", "gh api", "gh repo delete", "aws s3 rm",
    ]

    /// "npm test -- src/auth" -> "npm test"; "ls -la" -> "ls"; "npm run lint" -> "npm run lint". nil when unsafe.
    static func bashPrefix(_ command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first, !BashClassifier.isAssignment(first) else { return nil }
        let name = LexicalPath.lastComponent(first)
        if blockedFirstWords.contains(name) || name.hasPrefix("mkfs") { return nil }
        if first.contains("\"") || first.contains("'") || first.contains("\\") { return nil }

        guard subcommandTools.contains(name) || subcommandTools.contains(first) else { return first }
        guard words.count >= 2, isPlainWord(words[1]) else { return nil }
        var prefix = [first, words[1]]
        // `npm run <script>` / `pnpm exec <bin>`: the script or binary belongs in the prefix.
        // (`npx <pkg>` already has the package as its second word.)
        if runSubcommands.contains(words[1]) || groupedTools.contains(name) {
            guard words.count >= 3, isPlainWord(words[2]) else { return nil }
            prefix.append(words[2])
        }
        let text = prefix.joined(separator: " ")
        if blockedPrefixes.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) { return nil }
        return text
    }

    /// A subcommand-like word: letters, digits, `-`, `_`, `:`, `.`, `@`, `/`, not starting with `-`.
    private static func isPlainWord(_ w: String) -> Bool {
        guard let f = w.first, f != "-" else { return false }
        return w.allSatisfy { $0.isLetter || $0.isNumber || "-_:.@/".contains($0) }
    }

    // MARK: - Persistence

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// Writes `stored` atomically (temp file + rename). Caller holds `lock`, so saves never interleave.
    private func saveLocked() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best effort; the in-memory rules stay correct.
        }
    }
}
