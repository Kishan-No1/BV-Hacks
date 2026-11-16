// The local repo context: porcelain parsing, the exact git argv, and one run against a real temp repo.
import Foundation
import Testing
import NotchAgentCore

private typealias Provider = GitRepoContextProvider

/// Records every call and answers from a canned table. Calls arrive from several threads at once.
private final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var stdin: String?
        var timeout: TimeInterval
        var onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answer: @Sendable ([String]) -> CommandResult?

    init(_ answer: @escaping @Sendable ([String]) -> CommandResult?) { self.answer = answer }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) -> CommandResult? {
        lock.lock()
        recorded.append(Call(executable: executable, arguments: arguments, stdin: stdin, timeout: timeout,
                             onMainThread: Thread.isMainThread))
        lock.unlock()
        return answer(arguments)
    }
}

private let cwd = "/Users/me/code/app"
private let revParse = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
private let log = ["-C", cwd, "log", "-3", "--format=%s"]
private let status = ["-C", cwd, "status", "--porcelain", "-z"]

@Suite struct ParseStatusZTests {
    @Test func modifiedUntrackedAndStaged() {
        let output = " M src/a.ts\0?? notes.txt\0A  src/new.ts\0MM src/both.ts\0D  gone.ts\0"
        #expect(Provider.parseStatusZ(output) == ["src/a.ts", "notes.txt", "src/new.ts", "src/both.ts", "gone.ts"])
    }

    @Test func aRenameSkipsTheOriginalPath() {
        let output = "R  new/name.ts\0old/name.ts\0 M after.ts\0"
        #expect(Provider.parseStatusZ(output) == ["new/name.ts", "after.ts"])
    }

    @Test func copiesAndWorktreeRenamesSkipTheOriginalToo() {
        #expect(Provider.parseStatusZ("C  copy.ts\0source.ts\0?? x.ts\0") == ["copy.ts", "x.ts"])
        #expect(Provider.parseStatusZ(" R moved.ts\0was.ts\0RM both.ts\0prior.ts\0") == ["moved.ts", "both.ts"])
    }

    @Test func pathsWithSpacesAndUnicode() {
        let output = " M docs/read me.md\0?? 日本語/ファイル.txt\0A  café/naïve file.swift\0?? \u{0301}odd\0"
        #expect(Provider.parseStatusZ(output) == ["docs/read me.md", "日本語/ファイル.txt", "café/naïve file.swift", "\u{0301}odd"])
    }

    @Test func moreThanThirtyAreCapped() {
        let output = (1...45).map { " M file\($0).txt" }.joined(separator: "\0") + "\0"
        let names = Provider.parseStatusZ(output)
        #expect(Provider.maxChangedFiles == 30)
        #expect(names.count == 30)
        #expect(names.first == "file1.txt")
        #expect(names.last == "file30.txt")
    }

    @Test func duplicatesAreDroppedInOrder() {
        #expect(Provider.parseStatusZ("M  a.ts\0 M b.ts\0 M a.ts\0") == ["a.ts", "b.ts"])
    }

    @Test func emptyAndMalformedOutput() {
        #expect(Provider.parseStatusZ("") == [])
        #expect(Provider.parseStatusZ("\0\0") == [])
        #expect(Provider.parseStatusZ("M\0 M \0nospace\0 M ok.ts\0") == ["ok.ts"])
    }
}

@Suite struct AbbreviateTests {
    @Test func homeBecomesTilde() {
        #expect(Provider.abbreviate("/Users/me/x", home: "/Users/me") == "~/x")
        #expect(Provider.abbreviate("/Users/me/code/app", home: "/Users/me/") == "~/code/app")
        #expect(Provider.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(Provider.abbreviate("/Users/me/", home: "/Users/me") == "~")
    }

    @Test func otherPathsAreUntouched() {
        #expect(Provider.abbreviate("/Users/merlin/x", home: "/Users/me") == "/Users/merlin/x")
        #expect(Provider.abbreviate("/tmp/x", home: "/Users/me") == "/tmp/x")
        #expect(Provider.abbreviate("/tmp/x", home: "") == "/tmp/x")
        #expect(Provider.abbreviate("/tmp/x", home: "/") == "/tmp/x")
    }
}

@Suite struct GitRepoContextProviderTests {
    @MainActor @Test func runsExactlyTheThreeCommandsOffTheMainThread() async {
        let runner = FakeRunner { arguments in
            switch arguments {
            case revParse: return CommandResult(status: 0, stdout: "feature/x\n")
            case log: return CommandResult(status: 0, stdout: "subject 1\nsubject 2\nsubject 3\n")
            case status: return CommandResult(status: 0, stdout: " M src/a.ts\0R  new.ts\0old.ts\0?? notes.txt\0")
            default: return nil
            }
        }
        let context = await Provider(runner: runner, gitPath: "/fake/git", home: "/Users/me").context(cwd: cwd)
        #expect(context == RepoContext(cwd: "~/code/app", branch: "feature/x",
                                       commitSubjects: ["subject 1", "subject 2", "subject 3"],
                                       changedFiles: ["src/a.ts", "new.ts", "notes.txt"]))

        let calls = runner.calls
        #expect(calls.count == 3)
        #expect(Set(calls.map(\.arguments)) == [revParse, log, status])
        for call in calls {
            #expect(call.executable == "/fake/git")
            #expect(call.stdin == nil)
            #expect(call.timeout == 2)
            #expect(call.onMainThread == false)
        }
    }

    @Test func nilForEverythingGivesTheCwdOnly() async {
        let runner = FakeRunner { _ in nil }
        let context = await Provider(runner: runner, home: "/Users/me").context(cwd: cwd)
        #expect(context == RepoContext(cwd: "~/code/app"))
        #expect(runner.calls.count == 3)
    }

    @Test func notAGitRepoGivesTheCwdOnly() async {
        let runner = FakeRunner { _ in CommandResult(status: 128, stdout: "HEAD\n", stderr: "fatal: not a git repository") }
        let context = await Provider(runner: runner, home: "/Users/me").context(cwd: cwd)
        #expect(context == RepoContext(cwd: "~/code/app"))
    }

    @Test func aDetachedHeadHasNoBranch() async {
        let runner = FakeRunner { arguments in
            arguments == revParse ? CommandResult(status: 0, stdout: "HEAD\n") : CommandResult(status: 0, stdout: "")
        }
        let context = await Provider(runner: runner, home: "/Users/me").context(cwd: cwd)
        #expect(context == RepoContext(cwd: "~/code/app"))
    }

    @Test func oneFailedCommandLeavesOnlyItsFieldEmpty() async {
        let runner = FakeRunner { arguments in
            switch arguments {
            case revParse: return CommandResult(status: 0, stdout: "main\n")
            case log: return nil
            default: return CommandResult(status: 0, stdout: "?? a.txt\0")
            }
        }
        let context = await Provider(runner: runner, home: "/Users/me").context(cwd: cwd)
        #expect(context == RepoContext(cwd: "~/code/app", branch: "main", changedFiles: ["a.txt"]))
    }

    @Test func extraLogLinesAreCappedAtThree() async {
        let runner = FakeRunner { arguments in
            arguments == log ? CommandResult(status: 0, stdout: "a\n\nb\nc\nd\n") : nil
        }
        let context = await Provider(runner: runner, home: "/Users/me").context(cwd: cwd)
        #expect(context.commitSubjects == ["a", "b", "c"])
    }

    @Test func anEmptyOrRelativeCwdRunsNothing() async {
        let runner = FakeRunner { _ in CommandResult(status: 0, stdout: "main\n") }
        let provider = Provider(runner: runner, home: "/Users/me")
        #expect(await provider.context(cwd: "") == RepoContext(cwd: ""))
        #expect(await provider.context(cwd: "code/app") == RepoContext(cwd: "code/app"))
        #expect(runner.calls.isEmpty)
    }
}

@Suite struct GitRepoContextIntegrationTests {
    /// The user's own git config stays out of it: no global or system config, no signing, no hooks.
    private static let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0"]
    private static let gitPath = "/usr/bin/git"

    private func git(_ arguments: [String], in directory: String) throws {
        let identity = ["-c", "user.name=notchAgent Test", "-c", "user.email=notchagent@example.invalid",
                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        let result = ProcessCommandRunner(environment: Self.environment)
            .run(Self.gitPath, ["-C", directory] + identity + arguments, timeout: 20)
        let finished = try #require(result, "git \(arguments.first ?? "") did not run")
        try #require(finished.status == 0, "git \(arguments.first ?? "") exited \(finished.status)")
    }

    @Test func aRealRepoGivesNamesAndNeverContents() async throws {
        let marker = "NOTCH-AGENT-CONTENT-MARKER-\(UUID().uuidString)"
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-repo-context-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let tracked = repo.appendingPathComponent("tracked.txt")
        try git(["init", "-q", "-b", "trunk"], in: repo.path)
        for subject in ["commit one", "commit two", "commit three", "commit four"] {
            try Data("\(subject)\n".utf8).write(to: tracked)
            try git(["add", "tracked.txt"], in: repo.path)
            try git(["commit", "-q", "-m", subject], in: repo.path)
        }
        try Data("modified \(marker)\n".utf8).write(to: tracked)
        try Data("untracked \(marker)\n".utf8).write(to: repo.appendingPathComponent("untracked notes.txt"))

        let provider = Provider(runner: ProcessCommandRunner(environment: Self.environment),
                                gitPath: Self.gitPath, home: base.path)
        let context = await provider.context(cwd: repo.path)

        #expect(context.cwd == "~/repo")
        #expect(context.branch == "trunk")
        #expect(context.commitSubjects == ["commit four", "commit three", "commit two"])
        #expect(context.changedFiles.count == 2)
        #expect(Set(context.changedFiles) == ["tracked.txt", "untracked notes.txt"])

        // The marker lives only in file contents, so it can be nowhere in what is sent.
        let request = PolishRequest(raw: "tidy this up", notes: ["note one"], context: context)
        let prompt = PolishPrompt.user(request)
        #expect(prompt.contains("- tracked.txt"))
        #expect(prompt.contains("- untracked notes.txt"))
        #expect(!String(describing: context).contains(marker))
        #expect(!prompt.contains(marker))
        let body = try #require(AnthropicPolisher.makeRequest(request, apiKey: "test-key").httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains(marker))
    }

    @Test func aPlainDirectoryGivesTheCwdOnly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-repo-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // GIT_CEILING_DIRECTORIES stops git from finding a repo above the temp directory.
        var environment = Self.environment
        environment["GIT_CEILING_DIRECTORIES"] = base.deletingLastPathComponent().path
        let provider = Provider(runner: ProcessCommandRunner(environment: environment), gitPath: Self.gitPath, home: "/nowhere")
        #expect(await provider.context(cwd: base.path) == RepoContext(cwd: base.path))
    }
}
