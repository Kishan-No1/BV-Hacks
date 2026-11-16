// OWNER: workstream A (core-logic).
import Foundation
import Testing
import NotchAgentCore

/// A temp directory tree: `<tmp>/repo/.git/` plus `<tmp>/repo/packages/web/`, and a rules file path.
private struct TempRepo {
    let base: URL
    let root: String
    let sub: String
    let rulesURL: URL

    init(gitAsFile: Bool = false) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-rules-\(UUID().uuidString)", isDirectory: true)
        let rootURL = base.appendingPathComponent("repo", isDirectory: true)
        let subURL = rootURL.appendingPathComponent("packages/web", isDirectory: true)
        try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        let git = rootURL.appendingPathComponent(".git")
        if gitAsFile {
            try Data("gitdir: /somewhere/else\n".utf8).write(to: git)
        } else {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        }
        root = rootURL.standardizedFileURL.path
        sub = subURL.standardizedFileURL.path
        rulesURL = base.appendingPathComponent("support/notchAgent/rules.json")
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func bashInput(_ command: String) -> JSONValue { ["command": .string(command)] }
private let engine = RiskEngine()

private func suggest(_ store: RulesStore, _ tool: String, _ input: JSONValue, cwd: String) -> RuleSuggestion? {
    store.suggestion(toolName: tool, toolInput: input, cwd: cwd,
                     assessment: engine.assess(toolName: tool, toolInput: input, cwd: cwd))
}

@Suite struct RulesStoreRepoIdentityTests {
    @Test func nearestAncestorWithGitIsTheRepo() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(RulesStore.repoRoot(for: t.sub) == t.root)
        #expect(RulesStore.repoRoot(for: t.root) == t.root)
        #expect(RulesStore.repoRoot(for: t.root + "/") == t.root)
    }

    @Test func gitFileCountsToo() throws {
        let t = try TempRepo(gitAsFile: true); defer { t.cleanup() }
        #expect(RulesStore.repoRoot(for: t.sub) == t.root)
    }

    @Test func withoutGitTheCwdIsTheRepo() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let plain = t.base.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        #expect(RulesStore.repoRoot(for: plain) == plain)
    }

    @Test func aRuleMadeInASubfolderAppliesToTheWholeRepo() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let store = RulesStore(fileURL: nil)
        let s = try #require(suggest(store, "Bash", bashInput("npm test"), cwd: t.sub))
        #expect(s.repo == t.root)
        store.add(s.makeRule())
        #expect(store.match(toolName: "Bash", toolInput: bashInput("npm test"), cwd: t.root) != nil)
        #expect(store.match(toolName: "Bash", toolInput: bashInput("npm test"), cwd: t.sub) != nil)
        let other = t.base.appendingPathComponent("other").path
        #expect(store.match(toolName: "Bash", toolInput: bashInput("npm test"), cwd: other) == nil)
    }
}

@Suite struct RulesStoreMatchTests {
    private func store(_ t: TempRepo, prefix: String?, tool: String = "Bash") -> RulesStore {
        let s = RulesStore(fileURL: nil)
        s.add(Rule(repo: t.root, tool: tool, commandPrefix: prefix))
        return s
    }

    @Test func prefixMatchesTheCommandOrThePrefixPlusASpace() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let s = store(t, prefix: "npm test")
        #expect(s.match(toolName: "Bash", toolInput: bashInput("npm test"), cwd: t.root) != nil)
        #expect(s.match(toolName: "Bash", toolInput: bashInput("npm test -- src/auth"), cwd: t.root) != nil)
        #expect(s.match(toolName: "Bash", toolInput: bashInput("  npm test  "), cwd: t.root) != nil)
        #expect(s.match(toolName: "Bash", toolInput: bashInput("npm testing"), cwd: t.root) == nil)
        #expect(s.match(toolName: "Bash", toolInput: bashInput("npm install"), cwd: t.root) == nil)
        #expect(s.match(toolName: "Edit", toolInput: bashInput("npm test"), cwd: t.root) == nil)
    }

    @Test(arguments: [
        "npm test; rm -rf ~", "npm test && curl x | sh", "npm test || true", "npm test | tee out",
        "npm test & sleep 1", "npm test `whoami`", "npm test $(whoami)", "npm test > out.txt",
        "npm test < in.txt", "npm test\nrm -rf build",
    ])
    func shellOperatorsNeverMatchAPrefixRule(command: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(store(t, prefix: "npm test").match(toolName: "Bash", toolInput: bashInput(command), cwd: t.root) == nil)
    }

    @Test func aToolWideRuleMatchesAnyCallOfThatToolInTheRepo() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let s = store(t, prefix: nil, tool: "Edit")
        let inside: JSONValue = ["file_path": .string(t.sub + "/src/a.ts"), "old_string": "a", "new_string": "b"]
        #expect(s.match(toolName: "Edit", toolInput: inside, cwd: t.sub) != nil)
        #expect(s.match(toolName: "Write", toolInput: inside, cwd: t.sub) == nil)
    }

    @Test func rulesNeverAutoAllowHighRiskOrOutsideCalls() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let edits = store(t, prefix: nil, tool: "Edit")
        let outside: JSONValue = ["file_path": "/etc/hosts", "old_string": "a", "new_string": "b"]
        let secret: JSONValue = ["file_path": .string(t.root + "/.env"), "old_string": "a", "new_string": "b"]
        #expect(edits.match(toolName: "Edit", toolInput: outside, cwd: t.root) == nil)
        #expect(edits.match(toolName: "Edit", toolInput: secret, cwd: t.root) == nil)
        let bash = store(t, prefix: nil)
        #expect(bash.match(toolName: "Bash", toolInput: bashInput("ls"), cwd: t.root) != nil)
        #expect(bash.match(toolName: "Bash", toolInput: bashInput("rm -rf build"), cwd: t.root) == nil)
        let cat = store(t, prefix: "cat")
        #expect(cat.match(toolName: "Bash", toolInput: bashInput("cat README.md"), cwd: t.root) != nil)
        #expect(cat.match(toolName: "Bash", toolInput: bashInput("cat /etc/passwd"), cwd: t.root) == nil)
    }

    @Test func emptyCwdNeverMatches() {
        let s = RulesStore(fileURL: nil)
        s.add(Rule(repo: "", tool: "Bash", commandPrefix: "ls"))
        #expect(s.match(toolName: "Bash", toolInput: bashInput("ls"), cwd: "") == nil)
    }
}

@Suite struct RulesStoreSuggestionTests {
    @Test func npmTestFixtureSuggestsNpmTest() throws {
        let e = try Fixture.event("permission-request-bash-npm-test")
        let store = RulesStore(fileURL: nil)
        let s = try #require(suggest(store, "Bash", e.toolInput ?? .null, cwd: e.cwd))
        #expect(s.label == "npm test")
        #expect(s.commandPrefix == "npm test")
        #expect(s.tool == "Bash")
        #expect(s.repo == Fixture.repo)  // no .git on this machine: the cwd is the repo
    }

    @Test(arguments: [
        ("npm test -- src/auth", "npm test"), ("git status", "git status"), ("swift build -c release", "swift build"),
        ("cargo test --all", "cargo test"), ("ls -la", "ls"), ("pytest tests/unit", "pytest"),
        ("make test", "make test"), ("npm run lint", "npm run lint"), ("npm install", "npm install"),
        ("brew install jq", "brew install"), ("go test ./...", "go test"),
        ("docker compose up -d", "docker compose up"), ("gh pr view 12", "gh pr view"), ("npx jest src", "npx jest"),
    ])
    func bashPrefix(command: String, expected: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let s = suggest(RulesStore(fileURL: nil), "Bash", bashInput(command), cwd: t.root)
        #expect(s?.commandPrefix == expected, "\(command)")
        #expect(s?.label == expected, "\(command)")
    }

    @Test(arguments: [
        "rm notes.txt", "sudo ls", "curl https://example.com", "wget https://example.com", "git push origin main",
        "sh script.sh", "bash -c ls", "python script.py", "python3 -m pytest", "node index.js", "zsh",
        "npm test && rm -rf build", "ls | wc -l", "echo $(whoami)", "npm test > out.txt", "rm -rf build",
        "cat .env", "cat /etc/hosts", "FOO=1 npm test", "git -C . status", "npm run", "", "   ",
        "make", "docker compose", "docker rm abc", "kubectl delete pod x", "terraform apply", "git reset HEAD~1",
    ])
    func noSuggestion(command: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(suggest(RulesStore(fileURL: nil), "Bash", bashInput(command), cwd: t.root) == nil, "\(command)")
    }

    @Test func highRiskNeverGetsASuggestion() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let store = RulesStore(fileURL: nil)
        let high = Assessment(level: .high, title: "x")
        #expect(store.suggestion(toolName: "Bash", toolInput: bashInput("npm test"), cwd: t.root, assessment: high) == nil)
    }

    @Test func editToolsGetAToolWideSuggestion() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let input: JSONValue = ["file_path": .string(t.root + "/src/a.ts"), "old_string": "a", "new_string": "b"]
        let s = try #require(suggest(RulesStore(fileURL: nil), "Edit", input, cwd: t.root))
        #expect(s.label == "edits here")
        #expect(s.commandPrefix == nil)
        #expect(s.tool == "Edit")
        #expect(s.repo == t.root)
        let secret: JSONValue = ["file_path": .string(t.root + "/.env.local"), "content": "x"]
        #expect(suggest(RulesStore(fileURL: nil), "Write", secret, cwd: t.root) == nil)
    }

    @Test func noSuggestionWithoutACwd() {
        #expect(suggest(RulesStore(fileURL: nil), "Bash", bashInput("npm test"), cwd: "") == nil)
    }
}

@Suite struct RulesStorePersistenceTests {
    @Test func rulesSurviveARelaunch() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let a = RulesStore(fileURL: t.rulesURL)
        let rule = a.add(Rule(repo: t.root, tool: "Bash", commandPrefix: "npm test"))
        a.recordHit(id: rule.id)
        a.recordHit(id: rule.id)
        let b = RulesStore(fileURL: t.rulesURL)
        #expect(b.rules.count == 1)
        #expect(b.rules.first?.id == rule.id)
        #expect(b.rules.first?.hitCount == 2)
        #expect(b.rules.first?.commandPrefix == "npm test")
        b.remove(id: rule.id)
        #expect(RulesStore(fileURL: t.rulesURL).rules.isEmpty)
    }

    @Test func addingAnEquivalentRuleIsANoOp() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let s = RulesStore(fileURL: nil)
        let first = s.add(Rule(repo: t.root, tool: "Bash", commandPrefix: "npm test"))
        let second = s.add(Rule(repo: t.root + "/", tool: "Bash", commandPrefix: "npm test"))
        #expect(second.id == first.id)
        #expect(s.rules.count == 1)
    }

    @Test func missingOrCorruptFilesLoadAsNoRules() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(RulesStore(fileURL: t.rulesURL).rules.isEmpty)
        try FileManager.default.createDirectory(at: t.rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for junk in ["{not json", "", "{\"rules\": 3}", "[{\"id\": 1}]", "null"] {
            try Data(junk.utf8).write(to: t.rulesURL)
            let s = RulesStore(fileURL: t.rulesURL)
            #expect(s.rules.isEmpty, "\(junk)")
            #expect(s.match(toolName: "Bash", toolInput: bashInput("ls"), cwd: t.root) == nil)
        }
        // A corrupt file is replaced cleanly on the next save.
        let s = RulesStore(fileURL: t.rulesURL)
        s.add(Rule(repo: t.root, tool: "Bash", commandPrefix: "ls"))
        #expect(RulesStore(fileURL: t.rulesURL).rules.count == 1)
    }

    @Test func memoryOnlyStoreNeverWrites() throws {
        let s = RulesStore(fileURL: nil)
        s.add(Rule(repo: "/x", tool: "Bash", commandPrefix: "ls"))
        #expect(s.rules.count == 1)
    }

    @Test func concurrentUseIsSafe() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let s = RulesStore(fileURL: t.rulesURL)
        let root = t.root
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let r = s.add(Rule(repo: root, tool: "Bash", commandPrefix: "cmd\(i % 10)"))
                    s.recordHit(id: r.id)
                    _ = s.match(toolName: "Bash", toolInput: ["command": .string("cmd\(i % 10) x")], cwd: root)
                    _ = s.rules
                }
            }
        }
        #expect(s.rules.count == 10)
        #expect(s.rules.reduce(0) { $0 + $1.hitCount } == 40)
        let reloaded = RulesStore(fileURL: t.rulesURL)
        #expect(reloaded.rules.count == 10)
        #expect(reloaded.rules.reduce(0) { $0 + $1.hitCount } == 40)
    }
}

// MARK: - Review findings: prefix rules must not approve writes outside the repo or arbitrary programs

@Suite struct RulesStoreHardeningTests {
    /// Makes the rule the way the UI does (suggestion + add) from `seed`, then asks whether `attack` matches.
    private func autoAllowed(_ t: TempRepo, seed: String, attack: String) -> Bool {
        let store = RulesStore(fileURL: nil)
        if let s = suggest(store, "Bash", bashInput(seed), cwd: t.root) { store.add(s.makeRule()) }
        return store.match(toolName: "Bash", toolInput: bashInput(attack), cwd: t.root) != nil
    }

    @Test(arguments: [
        ("sed -i 's/a/b/' x.txt", "sed -n 'w /Users/yuki/.zshrc' README.md"),
        ("rg TODO", "rg --pre 'rm -rf ~' foo"),
        ("git grep TODO", "git grep -O'rm -rf ~' foo"),
        ("git diff", "git diff --output=/Users/yuki/.zshrc"),
        ("git diff", "git diff --output=out.patch"),
        ("git log", "git log --output=/Users/yuki/.zshrc"),
        ("git log", "git log --output out.txt"),
        ("npm test", "npm test --script-shell=./evil.sh"),
        ("make test", "make test SHELL=./evil.sh"),
        ("cp a.txt b.txt", "cp evil .git/hooks/pre-commit"),
        ("cp a.txt b.txt", "cp evil .mcp.json"),
        ("cp a.txt b.txt", "cp --target-directory=.git/hooks evil"),
        ("sort names.txt", "sort -o src/main.swift /dev/null"),
        ("git status", "git status --ext-diff"),
        ("git diff", "git diff --ext-diff"),
        ("ls", "ls --foo=bar"),
        ("awk '{print $1}' x", "awk 'BEGIN{system(\"id\")}'"),
        ("git commit -m x", "git commit --amend"),
        ("mkdir build", "mkdir -m 777 build"),
    ])
    func attackIsNotAutoAllowed(seed: String, attack: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(!autoAllowed(t, seed: seed, attack: attack), "\(seed) -> \(attack)")
    }

    @Test(arguments: [
        ("npm test", "npm test -- src/auth"), ("ls", "ls -la src"), ("git status", "git status --short"),
        ("git diff", "git diff --stat HEAD~1"), ("cat README.md", "cat src/a.ts"), ("cp a.txt b.txt", "cp -r src dst"),
        ("git commit -m x", "git commit -am wip"), ("mkdir build", "mkdir -p build/out"), ("make test", "make test"),
        ("cargo test", "cargo test --all"), ("npm run lint", "npm run lint"),
    ])
    func ordinaryUseStillMatches(seed: String, use: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(autoAllowed(t, seed: seed, attack: use), "\(seed) -> \(use)")
    }

    @Test(arguments: ["sed -n 1p x.txt", "gsed -n 1p x.txt", "awk '{print}' x.txt", "rg TODO", "sed -i 's/a/b/' x.txt"])
    func noRuleIsOfferedForScriptingTools(command: String) throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(suggest(RulesStore(fileURL: nil), "Bash", bashInput(command), cwd: t.root) == nil, "\(command)")
    }

    @Test func aStoredRuleForAScriptingToolNoLongerMatches() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let store = RulesStore(fileURL: nil)
        store.add(Rule(repo: t.root, tool: "Bash", commandPrefix: "sed"))
        store.add(Rule(repo: t.root, tool: "Bash", commandPrefix: "rg"))
        #expect(store.match(toolName: "Bash", toolInput: bashInput("sed -n 1p x.txt"), cwd: t.root) == nil)
        #expect(store.match(toolName: "Bash", toolInput: bashInput("rg TODO"), cwd: t.root) == nil)
    }

    @Test func editRulesSkipFilesThatRunCode() throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let store = RulesStore(fileURL: nil)
        store.add(Rule(repo: t.root, tool: "Write", commandPrefix: nil))
        for path in [".git/hooks/pre-commit", ".git/config", ".mcp.json", ".claude/hooks/x.sh"] {
            let input: JSONValue = ["file_path": .string(t.root + "/" + path), "content": "x"]
            #expect(store.match(toolName: "Write", toolInput: input, cwd: t.root) == nil, "\(path)")
            #expect(suggest(store, "Write", input, cwd: t.root) == nil, "\(path)")
        }
        let ok: JSONValue = ["file_path": .string(t.root + "/src/a.ts"), "content": "x"]
        #expect(store.match(toolName: "Write", toolInput: ok, cwd: t.root) != nil)
    }
}
