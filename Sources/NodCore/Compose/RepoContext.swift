// Local repo facts for the polish request: branch, the last 3 commit subjects, changed file NAMES.
// Three read-only git commands, run with an explicit argv (never a shell). No file is ever opened here,
// so no file contents and no diffs can reach the request.
import Foundation

public struct GitRepoContextProvider: RepoContextProviding {
    public static let maxChangedFiles = 30
    public static let maxCommits = 3
    public static let commandTimeout: TimeInterval = 2

    private let runner: CommandRunning
    private let gitPath: String
    private let home: String

    public init(runner: CommandRunning = ProcessCommandRunner(environment: ["GIT_OPTIONAL_LOCKS": "0"]),
                gitPath: String = "/usr/bin/git", home: String = NSHomeDirectory()) {
        self.runner = runner
        self.gitPath = gitPath
        self.home = home
    }

    /// Never throws and never blocks the caller's thread: the commands run on a background queue, side by
    /// side, so the worst case is one timeout rather than three.
    public func context(cwd: String) async -> RepoContext {
        var context = RepoContext(cwd: Self.abbreviate(cwd, home: home))
        // `git -C` with an empty or relative path would answer for the app's own directory.
        guard cwd.hasPrefix("/") else { return context }

        let commands: [[String]] = [
            ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            ["-C", cwd, "log", "-\(Self.maxCommits)", "--format=%s"],
            ["-C", cwd, "status", "--porcelain", "-z"],
        ]
        let runner = self.runner, gitPath = self.gitPath
        let outputs: [String?] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = Results(count: commands.count)
                DispatchQueue.concurrentPerform(iterations: commands.count) { i in
                    let result = runner.run(gitPath, commands[i], timeout: Self.commandTimeout)
                    if let result, result.status == 0 { results.set(i, result.stdout) }
                }
                continuation.resume(returning: results.get())
            }
        }

        if let branch = outputs[0]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !branch.isEmpty, branch != "HEAD" {   // "HEAD" is a detached head
            context.branch = branch
        }
        if let log = outputs[1] {
            context.commitSubjects = Array(
                log.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .prefix(Self.maxCommits))
        }
        if let status = outputs[2] {
            context.changedFiles = Self.parseStatusZ(status)
        }
        return context
    }

    /// Pure: names from `git status --porcelain -z` output. Entries are NUL-separated `XY <path>`; after a
    /// rename or copy the next entry is the original path and is skipped. Deduped, in order, capped.
    public static func parseStatusZ(_ output: String) -> [String] {
        // Scalars, not Characters: a path that starts with a combining mark would otherwise fuse with the
        // separator space into one grapheme and throw the offsets off.
        let entries = output.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: true)
        var names: [String] = []
        var seen = Set<String>()
        var skipNext = false
        for entry in entries {
            if skipNext { skipNext = false; continue }
            let scalars = Array(entry)
            guard scalars.count > 3, scalars[2] == " " else { continue }
            let x = scalars[0], y = scalars[1]
            if x == "R" || x == "C" || y == "R" || y == "C" { skipNext = true }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[3...])
            let name = String(view)
            guard seen.insert(name).inserted else { continue }
            names.append(name)
            if names.count == maxChangedFiles { break }
        }
        return names
    }

    /// Pure: "/Users/me/x" -> "~/x".
    public static func abbreviate(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home || path == home + "/" { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: String) { lock.lock(); values[index] = value; lock.unlock() }
    func get() -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
