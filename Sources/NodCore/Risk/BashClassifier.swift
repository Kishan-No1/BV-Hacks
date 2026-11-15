// OWNER: workstream A (core-logic).
import Foundation

/// Reason chips shown under a request title.
enum Reason {
    static let readOnly = "Read-only"
    static let inside = "Inside repo"
    static let outside = "Outside the project"
    static let network = "Network"
    static let secrets = "Secrets file"
    static let root = "Runs as root"
    static let cantUndo = "Can't undo"
    static let notInGit = "Not in git · can't undo"
    static let unfamiliar = "Unfamiliar command"
    static let unfamiliarTool = "Unfamiliar tool"
    static let changesFiles = "Changes files"
    static let changesRepo = "Changes the repo"
    static let runsScript = "Runs a script"
    static let dependencies = "Changes dependencies"
    static let writesFile = "Writes a file"
    static let runsProgram = "Runs a program"
    static let environment = "Changes the environment"
    static let customOptions = "Custom options"
    static let runsCodeLater = "Can run code later"
}

/// The verdict for one simple command, or several merged.
struct BashVerdict {
    var level: RiskLevel = .low
    /// Template title. nil means the generic "Run `<command>`".
    var title: String?
    var reasons: [String] = []
    /// Some path argument resolves outside the project.
    var outside = false
    /// Some path argument is a secrets file.
    var sensitive = false
}

/// Classifies a Bash `command` lexically. Pure: no disk, no network.
struct BashClassifier {
    /// Normalized project root (the session cwd). "" when unknown, which disables the outside rule.
    let root: String
    let home: String

    struct Context {
        /// Where relative paths resolve; follows `cd`.
        var cwd: String
    }

    // MARK: - Entry point

    func classify(_ command: String) -> BashVerdict {
        var ctx = Context(cwd: root)
        var v = analyze(ShellParser.parse(command), &ctx)
        if v.outside {
            v.reasons.removeAll { $0 == Reason.outside }
            v.reasons.insert(Reason.outside, at: 0)
        } else if !root.isEmpty {
            v.reasons.append(Reason.inside)
        }
        v.reasons = Array(Self.dedupe(v.reasons).prefix(3))
        return v
    }

    func analyze(_ segments: [ShellSegment], _ ctx: inout Context) -> BashVerdict {
        var verdicts: [BashVerdict] = []
        for s in segments { verdicts += segmentVerdicts(s, &ctx) }
        if Self.runsRemoteScript(segments) {
            // Last, so its title wins over the high-risk segments it is made of.
            verdicts.append(BashVerdict(level: .high, title: "Run a script from the internet",
                                        reasons: [Reason.network, "Runs remote code"]))
        }
        return combine(verdicts)
    }

    /// The highest level wins. The title comes from the last verdict at that level that has a template title
    /// (`git add && git commit` reads "Commit changes"); reasons come from every verdict at that level.
    func combine(_ verdicts: [BashVerdict]) -> BashVerdict {
        guard let maxLevel = verdicts.map(\.level).max() else {
            return BashVerdict(level: .low, reasons: [Reason.readOnly])
        }
        let top = verdicts.filter { $0.level == maxLevel }
        let title = top.last(where: { $0.title != nil })?.title
        var out = BashVerdict(level: maxLevel, title: title, reasons: Self.dedupe(top.reversed().flatMap(\.reasons)))
        out.outside = verdicts.contains { $0.outside }
        out.sensitive = verdicts.contains { $0.sensitive }
        if maxLevel == .low { out.reasons = [Reason.readOnly] }
        return out
    }

    // MARK: - Segments

    struct CommandResult {
        var verdict: BashVerdict
        /// Words naming files the command reads or acts on.
        var paths: [String] = []
        /// Words naming files the command writes.
        var written: [String] = []
        /// `cd` target, applied to the context after this segment.
        var cd: String?
    }

    func segmentVerdicts(_ seg: ShellSegment, _ ctx: inout Context) -> [BashVerdict] {
        var out: [BashVerdict] = []
        for sub in seg.substitutions where !sub.isEmpty {
            var subCtx = ctx
            out.append(analyze(sub, &subCtx))
        }
        let stripped = Self.stripKeywords(seg.words)
        let (words, sudo, env) = Self.unwrap(stripped)
        var result: CommandResult
        if !words.isEmpty {
            result = command(words, &ctx)
            if env, result.verdict.level == .low {
                // PATH=…, GIT_EXTERNAL_DIFF=…, DYLD_…: the variable can change which program really runs.
                result.verdict = review(reasons: [Reason.environment])
            }
        } else if sudo {
            result = CommandResult(verdict: BashVerdict(level: .high))
        } else if seg.redirects.contains(where: \.opensFile) {
            result = CommandResult(verdict: low())
        } else if stripped.contains(where: { Self.isAssignment($0) && Self.isRiskyShellVariable($0) }) {
            // `PATH=./evil:$PATH` on its own changes what the next commands run.
            result = CommandResult(verdict: review(reasons: [Reason.environment]))
        } else {
            return out  // assignment-only, keyword-only or empty
        }
        for r in seg.redirects where r.opensFile {
            guard let t = r.target else { continue }
            if r.writes { result.written.append(t) } else { result.paths.append(t) }
        }
        var v = result.verdict
        apply(paths: result.paths, written: result.written, to: &v, ctx: ctx)
        if sudo {
            if v.level < .high || v.title == nil { v.title = "Run a command as root" }
            v.level = .high
            v.reasons.removeAll { $0 == Reason.readOnly }
            v.reasons.insert(Reason.root, at: 0)
        }
        out.append(v)
        if let target = result.cd { ctx.cwd = resolve(target, ctx) }
        return out
    }

    /// Applies the path rules: secrets writes are high, other writes at least review,
    /// secrets reads and paths outside the project each raise the level one step.
    func apply(paths: [String], written: [String], to v: inout BashVerdict, ctx: Context) {
        let writes = written.filter(Self.isPathWord).map { resolve($0, ctx) }.filter { !LexicalPath.isExemptDevice($0) }
        let reads = paths.filter(Self.isPathWord).map { resolve($0, ctx) }.filter { !LexicalPath.isExemptDevice($0) }

        if let secret = writes.first(where: LexicalPath.isSensitive) {
            v.sensitive = true
            if v.level < .high || v.title == nil { v.title = "Write \(LexicalPath.lastComponent(secret))" }
            v.level = .high
            v.reasons.removeAll { $0 == Reason.readOnly }
            v.reasons.insert(Reason.secrets, at: 0)
        } else if let config = writes.first(where: LexicalPath.isCodeConfig) {
            // .git/hooks, .git/config, .mcp.json, .claude/: files that make later commands run code.
            v.sensitive = true
            if v.level < .high || v.title == nil { v.title = "Write \(LexicalPath.lastComponent(config))" }
            v.level = .high
            v.reasons.removeAll { $0 == Reason.readOnly }
            v.reasons.insert(Reason.runsCodeLater, at: 0)
        } else if let first = writes.first, v.level == .low {
            v.level = .review
            v.title = writes.count == 1 ? "Write \(LexicalPath.lastComponent(first))" : "Write files"
            v.reasons = [Reason.writesFile]
        }
        if !v.sensitive, reads.contains(where: LexicalPath.isSensitive) {
            v.sensitive = true
            v.level = v.level.raised
            v.reasons.insert(Reason.secrets, at: 0)
        }
        if (reads + writes).contains(where: leavesRoot) {
            v.outside = true
            v.level = v.level.raised
        }
    }

    // MARK: - Commands

    func command(_ words: [String], _ ctx: inout Context) -> CommandResult {
        let name = Self.commandName(words[0])
        let args = Array(words.dropFirst())
        let pos = Self.positional(args)
        var paths = pos
        // A script run by a relative or home path (./x.sh, ../x.sh, ~/x.sh) is a path too.
        if words[0].hasPrefix(".") || words[0].hasPrefix("~") { paths.append(words[0]) }

        switch name {
        case "cd", "pushd":
            guard let target = pos.first else { return CommandResult(verdict: low(), cd: "~") }
            if target == "-" { return CommandResult(verdict: low()) }
            return CommandResult(verdict: low(), paths: [target], cd: target)
        case "popd":
            return CommandResult(verdict: low())
        case "echo", "printf":
            return CommandResult(verdict: low())
        case "sort":
            // `-o FILE` overwrites FILE; `--compress-program` runs a program.
            var written: [String] = []
            var runs = false
            for (i, a) in args.enumerated() {
                if a == "-o" || a == "--output" { if i + 1 < args.count { written.append(args[i + 1]) } }
                else if a.hasPrefix("--output=") { written.append(String(a.dropFirst("--output=".count))) }
                else if a.hasPrefix("-o"), a.count > 2 { written.append(String(a.dropFirst(2))) }
                else if a.hasPrefix("--compress-program") { runs = true }
            }
            if runs { return CommandResult(verdict: review(reasons: [Reason.runsProgram]), paths: paths, written: written) }
            return CommandResult(verdict: low(), paths: paths, written: written)
        case "uniq":
            // `uniq IN OUT` overwrites OUT.
            let operands = Self.operands(args, valueFlags: ["-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"])
            return CommandResult(verdict: low(), paths: Array(operands.prefix(1)), written: Array(operands.dropFirst()))
        case "tree":
            var written: [String] = []
            for (i, a) in args.enumerated() where a == "-o" || a == "--output" {
                if i + 1 < args.count { written.append(args[i + 1]) }
            }
            return CommandResult(verdict: low(), paths: paths, written: written)
        case "xxd":
            // `xxd IN OUT` and `xxd -r IN OUT` write OUT.
            let operands = Self.operands(args, valueFlags: ["-l", "-len", "-s", "-seek", "-c", "-cols", "-g", "-o", "-n", "-name"])
            return CommandResult(verdict: low(), paths: Array(operands.prefix(1)), written: Array(operands.dropFirst()))
        case "fd":
            if let x = args.firstIndex(where: { ["-x", "-X", "--exec", "--exec-batch"].contains($0) }) {
                var v = review(reasons: ["Runs a command on each file"])
                let inner = nested(args[(x + 1)...].joined(separator: " "), ctx)
                if inner.level > v.level { v = inner }
                return CommandResult(verdict: v)
            }
            return CommandResult(verdict: low(), paths: paths)
        case _ where Self.readOnlyCommands.contains(name):
            // `bat --pager=CMD`, `less`-style pagers given by flag run a program.
            if args.contains(where: { $0.hasPrefix("--pager") }) {
                return CommandResult(verdict: review(reasons: [Reason.runsProgram]), paths: paths)
            }
            return CommandResult(verdict: low(), paths: paths)
        case "grep", "egrep", "fgrep", "rg", "ag", "ack", "jq":
            let files = Self.dropPattern(args, patternFlags: ["-e", "--regexp", "-f", "--file"])
            // `rg --pre CMD`, `rg --hostname-bin CMD`, `ack --pager=CMD` run CMD.
            for (i, a) in args.enumerated() {
                for flag in ["--pre", "--hostname-bin", "--pager"] {
                    if a == flag {
                        return CommandResult(verdict: runsProgram(i + 1 < args.count ? args[i + 1] : nil, ctx), paths: files)
                    }
                    if a.hasPrefix(flag + "=") {
                        return CommandResult(verdict: runsProgram(String(a.dropFirst(flag.count + 1)), ctx), paths: files)
                    }
                }
            }
            return CommandResult(verdict: low(), paths: files)
        case "sed", "gsed":
            return sed(args)
        case "find":
            return find(args, ctx)
        case "git":
            return git(args, ctx)
        case "npm", "pnpm", "yarn", "bun":
            return nodePackageManager(name, args, paths: paths)
        case "npx", "bunx", "pnpx":
            return CommandResult(verdict: review(reasons: [Reason.network, "Runs a package"]), paths: paths)
        case "pytest", "py.test", "jest", "vitest", "mocha", "tsc":
            return CommandResult(verdict: low(), paths: paths)
        case "eslint":
            return CommandResult(verdict: args.contains("--fix") ? review(reasons: [Reason.changesFiles]) : low(), paths: paths)
        case "prettier":
            let check = args.contains { ["--check", "-c", "--list-different", "-l"].contains($0) }
            return CommandResult(verdict: check ? low() : review(reasons: [Reason.changesFiles]), paths: paths)
        case "python", "python2", "python3":
            if let m = args.firstIndex(of: "-m"), m + 1 < args.count {
                let module = args[m + 1]
                if module == "pytest" || module == "unittest" { return CommandResult(verdict: low(), paths: paths) }
                if module == "pip" || module == "pip3" {
                    return packageManager(Array(args[(m + 2)...]), paths: paths)
                }
            }
            return CommandResult(verdict: review(reasons: [Reason.runsScript]), paths: paths)
        case "pip", "pip3", "pipx", "uv", "poetry", "gem", "bundle", "composer", "apt", "apt-get", "yum", "dnf",
             "port", "pod", "brew", "mix":
            var rest = args
            if name == "uv", rest.first == "pip" { rest = Array(rest.dropFirst()) }
            return packageManager(rest, paths: paths)
        case "swift":
            guard let sub = Self.firstNonFlag(args) else { return CommandResult(verdict: review(reasons: [Reason.unfamiliar])) }
            if ["build", "test"].contains(sub) { return CommandResult(verdict: low(), paths: paths) }
            if sub == "package", let action = Self.firstNonFlag(Array(args.drop { $0 != "package" }.dropFirst())) {
                if ["resolve", "update"].contains(action) { return CommandResult(verdict: installVerdict(action), paths: paths) }
                if ["describe", "dump-package", "show-dependencies"].contains(action) { return CommandResult(verdict: low(), paths: paths) }
            }
            return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
        case "cargo":
            let sub = Self.firstNonFlag(args) ?? ""
            if ["build", "b", "test", "t", "check", "c", "clippy", "doc", "bench", "tree", "metadata"].contains(sub) {
                // `--config KEY=VALUE` can swap the compiler, linker or test runner.
                if args.contains(where: { $0.hasPrefix("--config") }) {
                    return CommandResult(verdict: review(reasons: [Reason.customOptions]), paths: paths)
                }
                return CommandResult(verdict: low(), paths: paths)
            }
            if ["install", "add", "update", "fetch", "remove", "uninstall"].contains(sub) {
                return CommandResult(verdict: installVerdict(sub), paths: paths)
            }
            return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
        case "go":
            let sub = Self.firstNonFlag(args) ?? ""
            if ["build", "test", "vet", "list", "version", "env", "doc"].contains(sub) {
                // `-exec PROG`, `-toolexec PROG`, `-vettool PROG` run PROG; `go env -w` writes the go config.
                let runs = args.contains { a in
                    ["-exec", "--exec", "-toolexec", "--toolexec", "-vettool", "--vettool", "-w"].contains { a == $0 || a.hasPrefix($0 + "=") }
                }
                if runs { return CommandResult(verdict: review(reasons: [Reason.customOptions]), paths: paths) }
                return CommandResult(verdict: low(), paths: paths)
            }
            if ["get", "install"].contains(sub) || (sub == "mod" && args.contains { ["download", "tidy"].contains($0) }) {
                return CommandResult(verdict: installVerdict("install"), paths: paths)
            }
            return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
        case "make", "gmake":
            return make(args)
        case "curl", "wget", "http", "https", "aria2c":
            return download(name, args)
        case "rm":
            return rm(args, ctx)
        case "rmdir", "unlink", "trash", "srm", "shred":
            return CommandResult(verdict: review(title: "Delete files", reasons: [Reason.cantUndo]), paths: paths)
        case "chmod", "chown", "chgrp":
            return permissions(name, args)
        case "dd":
            var reads: [String] = [], writes: [String] = []
            for a in args {
                if a.hasPrefix("if=") { reads.append(String(a.dropFirst(3))) }
                if a.hasPrefix("of=") { writes.append(String(a.dropFirst(3))) }
            }
            return CommandResult(verdict: BashVerdict(level: .high, title: "Write raw data with dd", reasons: [Reason.cantUndo]),
                                 paths: reads, written: writes)
        case "diskutil":
            let erase = args.contains { ["eraseDisk", "eraseVolume", "partitionDisk", "zeroDisk", "randomDisk", "secureErase", "reformat"].contains($0) }
            if erase { return CommandResult(verdict: formatVerdict()) }
            return CommandResult(verdict: review(reasons: [Reason.unfamiliar]))
        case _ where name.hasPrefix("mkfs") || name.hasPrefix("newfs"):
            return CommandResult(verdict: formatVerdict(), paths: paths)
        case "sh", "bash", "zsh", "dash", "ksh", "fish":
            if let c = args.firstIndex(where: { $0 == "-c" || ($0.count > 1 && $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")) }),
               c + 1 < args.count {
                return CommandResult(verdict: nested(args[c + 1], ctx))
            }
            return CommandResult(verdict: review(reasons: [Reason.runsScript]), paths: paths)
        case "eval":
            return CommandResult(verdict: nested(args.joined(separator: " "), ctx))
        case "source", ".", "node", "deno", "ruby", "perl", "php", "osascript", "lua", "Rscript":
            return CommandResult(verdict: review(reasons: [Reason.runsScript]), paths: paths)
        case "cp", "mv", "ln", "install", "rsync", "scp", "ditto":
            return CommandResult(verdict: review(reasons: [Reason.changesFiles]),
                                 paths: Array(pos.dropLast()), written: pos.last.map { [$0] } ?? [])
        case "tee", "touch", "truncate", "mkdir":
            return CommandResult(verdict: review(reasons: [Reason.changesFiles]), written: pos)
        case "kill", "killall", "pkill":
            return CommandResult(verdict: review(reasons: ["Stops processes"]))
        case "ssh", "sftp", "nc", "telnet", "ftp":
            return CommandResult(verdict: review(reasons: [Reason.network]), paths: paths)
        default:
            return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
        }
    }

    /// `bash -c "..."` and `eval ...`: classify the inner command; running a shell is at least review.
    private func nested(_ text: String, _ ctx: Context) -> BashVerdict {
        var sub = ctx
        let cleaned = text.replacingOccurrences(of: ShellParser.substitutionWord, with: "_")
        var v = analyze(ShellParser.parse(cleaned), &sub)
        if v.level < .review {
            v.level = .review
            v.title = nil
            v.reasons = [Reason.runsScript]
        }
        return v
    }

    /// An option whose value is a program to run (`rg --pre CMD`, `git -c core.pager=CMD`): the value is
    /// classified as a command of its own and is at least review.
    private func runsProgram(_ value: String?, _ ctx: Context) -> BashVerdict {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return review(reasons: [Reason.runsProgram])
        }
        var v = nested(value, ctx)
        if v.level == .review, v.title == nil { v.reasons = Self.dedupe([Reason.runsProgram] + v.reasons) }
        return v
    }

    /// `sed`: in-place edits change files; a script with `w FILE`, `r FILE` or GNU `e CMD` writes files or
    /// runs programs, so anything but a plain print/delete/substitute script is review.
    private func sed(_ args: [String]) -> CommandResult {
        var scripts: [String] = []
        var scriptFromFile = false
        var inPlace = false
        var operands: [String] = []
        var i = 0
        var afterDoubleDash = false
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            i += 1
            if afterDoubleDash { operands.append(a); continue }
            if a == "--" { afterDoubleDash = true; continue }
            if a == "-e" || a == "--expression" {
                if let next { scripts.append(next) }
                i += 1
            } else if a.hasPrefix("--expression=") {
                scripts.append(String(a.dropFirst("--expression=".count)))
            } else if a == "-f" || a == "--file" {
                scriptFromFile = true
                i += 1
            } else if a.hasPrefix("--file=") {
                scriptFromFile = true
            } else if a.hasPrefix("--in-place") {
                inPlace = true
            } else if a == "-i" {
                inPlace = true
                if next == "" { i += 1 }  // BSD `sed -i '' …`
            } else if a.hasPrefix("--") {
                continue
            } else if a.hasPrefix("-"), a.count > 1 {
                let cluster = a.dropFirst()
                if a.hasPrefix("-i") { inPlace = true; continue }  // -i.bak
                if cluster.contains("i") { inPlace = true }
                if cluster.contains("f") { scriptFromFile = true; i += 1 }
                else if cluster.hasSuffix("e") {
                    if let next { scripts.append(next) }
                    i += 1
                }
            } else {
                operands.append(a)
            }
        }
        if scripts.isEmpty, !scriptFromFile, !operands.isEmpty { scripts = [operands.removeFirst()] }
        let plain = !scriptFromFile && scripts.allSatisfy(Self.sedScriptIsPlain)
        if !plain {
            return CommandResult(verdict: review(reasons: ["Runs a sed script"]),
                                 paths: inPlace ? [] : operands, written: inPlace ? operands : [])
        }
        if inPlace { return CommandResult(verdict: review(reasons: [Reason.changesFiles]), written: operands) }
        return CommandResult(verdict: low(), paths: operands)
    }

    /// True for scripts made only of `p d q D G g H h N n P x l =`, `s/…/…/[gpIi0-9]` and `y/…/…/` commands
    /// with simple addresses, separated by `;`. Everything else (`w`, `r`, `e`, blocks, labels, `a`/`i`/`c`
    /// text, the `w` and `e` flags of `s`) is "not plain".
    static func sedScriptIsPlain(_ script: String) -> Bool {
        let c = Array(script)
        var i = 0
        func skipSpaces() { while i < c.count, c[i] == " " { i += 1 } }
        func delimited(_ d: Character) -> Bool {
            while i < c.count, c[i] != d {
                if c[i] == "\\" { i += 1 }
                i += 1
            }
            guard i < c.count else { return false }
            i += 1
            return true
        }
        func address() -> Bool {
            guard i < c.count else { return true }
            if c[i].isASCII, c[i].isNumber {
                while i < c.count, c[i].isASCII, c[i].isNumber { i += 1 }
            } else if c[i] == "$" {
                i += 1
            } else if c[i] == "/" {
                i += 1
                return delimited("/")
            }
            return true
        }
        while true {
            skipSpaces()
            guard address() else { return false }
            skipSpaces()
            if i < c.count, c[i] == "," {
                i += 1
                skipSpaces()
                if i < c.count, c[i] == "+" { i += 1 }
                guard address() else { return false }
                skipSpaces()
            }
            if i < c.count, c[i] == "!" { i += 1; skipSpaces() }
            if i < c.count, c[i] != ";" {
                let cmd = c[i]
                i += 1
                if cmd == "s" || cmd == "y" {
                    guard i < c.count else { return false }
                    let d = c[i]
                    guard d != "\\", d != "\n", d != " ", !d.isLetter, !d.isNumber else { return false }
                    i += 1
                    guard delimited(d), delimited(d) else { return false }
                    if cmd == "s" { while i < c.count, "gpIi0123456789".contains(c[i]) { i += 1 } }
                } else if !"pdqDGgHhNnPxl=".contains(cmd) {
                    return false
                }
            }
            skipSpaces()
            if i >= c.count { return true }
            guard c[i] == ";" else { return false }
            i += 1
        }
    }

    private func find(_ args: [String], _ ctx: Context) -> CommandResult {
        var i = 0
        while i < args.count, ["-H", "-L", "-P", "-E", "-X", "-s", "-x"].contains(args[i]) { i += 1 }
        var starts: [String] = []
        while i < args.count, !args[i].hasPrefix("-"), args[i] != "(", args[i] != "!" { starts.append(args[i]); i += 1 }

        if args.contains("-delete") {
            let outside = starts.contains { leaves($0, ctx) }
            return CommandResult(verdict: BashVerdict(level: .high, title: outside ? "Delete files outside this repo" : "Delete files",
                                                      reasons: [outside ? Reason.notInGit : Reason.cantUndo]),
                                 paths: starts)
        }
        if let e = args.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            var sub: [String] = []
            var j = e + 1
            while j < args.count, args[j] != ";", args[j] != "+" { sub.append(args[j]); j += 1 }
            var result = CommandResult(verdict: review(reasons: ["Runs a command on each file"]), paths: starts)
            let (words, sudo, _) = Self.unwrap(sub)
            if sudo { result.verdict = BashVerdict(level: .high, title: "Run a command as root", reasons: [Reason.root]) }
            if !words.isEmpty {
                var c = ctx
                let inner = command(words, &c)
                if inner.verdict.level >= .review, inner.verdict.level >= result.verdict.level, !(sudo && inner.verdict.level < .high) {
                    result.verdict = inner.verdict
                }
                result.paths += inner.paths
                result.written += inner.written
            }
            return result
        }
        if args.contains(where: { ["-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }) {
            return CommandResult(verdict: review(reasons: [Reason.changesFiles]), paths: starts)
        }
        return CommandResult(verdict: low(), paths: starts)
    }

    /// git config keys whose value is a program git runs.
    private static let gitProgramKeys = [
        "fsmonitor", "pager", "editor", "sshcommand", "hookspath", "external", "textconv", "alias.", "helper",
        "proxy", "filter.", "program", "cmd", "command", "askpass", "exec", "driver", "browser", "sendmail",
    ]

    /// `git -c KEY=VALUE`: review; when KEY names a program (core.fsmonitor, core.pager, diff.external,
    /// alias.x, ...) VALUE is classified as the command it is.
    private func gitConfigOverride(_ setting: String?, _ ctx: Context) -> BashVerdict {
        guard let setting, let eq = setting.firstIndex(of: "=") else { return review(reasons: ["Overrides git config"]) }
        let key = setting[..<eq].lowercased()
        var value = String(setting[setting.index(after: eq)...])
        guard Self.gitProgramKeys.contains(where: key.contains) else { return review(reasons: ["Overrides git config"]) }
        if value.hasPrefix("!") { value.removeFirst() }  // alias.x='!cmd'
        return runsProgram(value, ctx)
    }

    private func git(_ args: [String], _ ctx: Context) -> CommandResult {
        var i = 0
        var paths: [String] = []
        var written: [String] = []
        /// From options that override config or run programs; the final verdict is never below it.
        var floor: BashVerdict?
        func raise(_ v: BashVerdict) { if v.level >= (floor?.level ?? .low) { floor = v } }
        while i < args.count, args[i].hasPrefix("-") {
            let a = args[i]
            if a == "-C" || a == "--git-dir" || a == "--work-tree" {
                if i + 1 < args.count { paths.append(args[i + 1]) }
                i += 2; continue
            }
            if a == "-c" || a == "--config-env" {
                raise(a == "-c" ? gitConfigOverride(i + 1 < args.count ? args[i + 1] : nil, ctx) : review(reasons: ["Overrides git config"]))
                i += 2; continue
            }
            if a == "--namespace" { i += 2; continue }
            if a.hasPrefix("--config-env=") || a.hasPrefix("--exec-path=") || (a.hasPrefix("-c") && a.count > 2) {
                raise(review(reasons: ["Overrides git config"]))
            }
            if a.hasPrefix("--git-dir=") || a.hasPrefix("--work-tree="), let eq = a.firstIndex(of: "=") {
                paths.append(String(a[a.index(after: eq)...]))
            }
            i += 1
        }
        guard i < args.count else {
            return CommandResult(verdict: floor ?? low(), paths: paths)
        }
        let sub = args[i]
        let rest = Array(args[(i + 1)...])
        let flags = rest.filter { $0.hasPrefix("-") && $0 != "--" }
        let messageSubs: Set<String> = ["commit", "tag", "stash", "merge", "notes"]
        var pos: [String] = []
        var skipNext = false, sawDoubleDash = false
        for a in rest {
            if skipNext { skipNext = false; continue }
            if sawDoubleDash { pos.append(a); continue }
            if a == "--" { sawDoubleDash = true; continue }
            if messageSubs.contains(sub),
               a == "-m" || a == "--message" || (a.count > 2 && a.hasPrefix("-") && !a.hasPrefix("--") && a.hasSuffix("m")) {
                skipNext = true; continue
            }
            if a.hasPrefix("-") { continue }
            pos.append(a)
        }
        if sub == "grep" { pos = Array(pos.dropFirst()) }  // the pattern
        paths += pos
        // Options that write a file or run a program, on any subcommand.
        for (k, a) in rest.enumerated() {
            if a == "--" { break }
            let next = k + 1 < rest.count ? rest[k + 1] : nil
            if a == "--output" { if let next { written.append(next) } }
            else if a.hasPrefix("--output=") { written.append(String(a.dropFirst("--output=".count))) }
            else if a == "--ext-diff" { raise(review(reasons: [Reason.runsProgram])) }
            else if sub == "grep", a.hasPrefix("--open-files-in-pager") {
                raise(runsProgram(a.contains("=") ? String(a[a.index(after: a.firstIndex(of: "=")!)...]) : nil, ctx))
            } else if sub == "grep", a.hasPrefix("-"), !a.hasPrefix("--"), let o = a.firstIndex(of: "O") {
                raise(runsProgram(String(a[a.index(after: o)...]), ctx))  // -O[<pager>]
            } else {
                for flag in ["--upload-pack", "--receive-pack", "--exec"] {
                    if a == flag { raise(runsProgram(next, ctx)) }
                    else if a.hasPrefix(flag + "=") { raise(runsProgram(String(a.dropFirst(flag.count + 1)), ctx)) }
                }
            }
        }
        func shortFlag(_ ch: Character) -> Bool { flags.contains { !$0.hasPrefix("--") && $0.dropFirst().contains(ch) } }
        func result(_ v: BashVerdict) -> CommandResult {
            if let floor, floor.level >= v.level, floor.level > .low {
                return CommandResult(verdict: floor, paths: paths, written: written)
            }
            return CommandResult(verdict: v, paths: paths, written: written)
        }
        let changes = review(reasons: [Reason.changesRepo])

        switch sub {
        case "status", "diff", "log", "show", "blame", "ls-files", "ls-tree", "rev-parse", "describe", "shortlog",
             "grep", "whatchanged", "cat-file", "rev-list", "help", "version", "show-ref", "for-each-ref", "name-rev",
             "count-objects", "check-ignore", "diff-tree", "diff-files", "diff-index", "merge-base", "show-branch":
            return result(low())
        case "branch":
            let deleting = flags.contains { ["-d", "-D", "--delete"].contains($0) }
            if deleting { return result(review(title: "Delete a branch", reasons: [Reason.changesRepo])) }
            let listing = ["-a", "-r", "-v", "-vv", "--all", "--remotes", "--list", "-l", "--show-current", "--merged", "--no-merged", "--contains"]
            if pos.isEmpty, flags.allSatisfy({ listing.contains($0) || $0.hasPrefix("--sort") || $0.hasPrefix("--format") }) {
                return result(low())
            }
            return result(changes)
        case "remote":
            if pos.isEmpty || ["show", "get-url"].contains(pos[0]) { return result(low()) }
            return result(changes)
        case "stash":
            if let first = pos.first, ["list", "show"].contains(first) { return result(low()) }
            return result(changes)
        case "tag":
            if pos.isEmpty, !flags.contains(where: { ["-d", "--delete", "-a", "-s", "-f", "--force"].contains($0) }) { return result(low()) }
            return result(changes)
        case "config":
            let reading = flags.contains { ["--get", "--get-all", "--list", "-l", "--get-regexp", "--show-origin"].contains($0) }
            if reading || (pos.count <= 1 && flags.isEmpty) { return result(low()) }
            return result(changes)
        case "worktree":
            return result(pos.first == "list" ? low() : changes)
        case "reflog":
            return result(pos.isEmpty || pos.first == "show" ? low() : changes)
        case "push":
            let force = flags.contains { $0 == "--force" || $0.hasPrefix("--force-with-lease") || $0 == "--force-if-includes" || $0 == "--mirror" }
                || shortFlag("f") || pos.contains { $0.hasPrefix("+") }
            if force { return result(BashVerdict(level: .high, title: "Force-push to the remote", reasons: ["Rewrites remote history", Reason.network])) }
            return result(review(title: "Push to the remote", reasons: [Reason.network]))
        case "reset":
            if flags.contains("--hard") { return result(BashVerdict(level: .high, title: "Discard local changes", reasons: [Reason.cantUndo])) }
            return result(changes)
        case "clean":
            if flags.contains("--force") || shortFlag("f") {
                return result(BashVerdict(level: .high, title: "Delete untracked files", reasons: [Reason.cantUndo]))
            }
            return result(changes)
        case "checkout":
            if sawDoubleDash || pos.contains(".") { return result(review(title: "Discard local changes", reasons: [Reason.cantUndo])) }
            return result(changes)
        case "restore":
            if !flags.contains("--staged") && !flags.contains("-S") {
                return result(review(title: "Discard local changes", reasons: [Reason.cantUndo]))
            }
            return result(changes)
        case "pull": return result(review(title: "Pull from the remote", reasons: [Reason.network]))
        case "fetch": return result(review(title: "Fetch from the remote", reasons: [Reason.network]))
        case "clone": return result(review(title: "Clone a repository", reasons: [Reason.network]))
        case "commit": return result(review(title: "Commit changes", reasons: [Reason.changesRepo]))
        case "add": return result(review(title: "Stage changes", reasons: [Reason.changesRepo]))
        default: return result(changes)
        }
    }

    private static let lowScripts: Set<String> = ["test", "lint", "build", "typecheck", "type-check", "tsc", "check", "types"]

    private static func isLowScript(_ script: String) -> Bool {
        let base = script.split(separator: ":").first.map(String.init) ?? script
        guard lowScripts.contains(base) else { return false }
        let lower = script.lowercased()
        return !["fix", "deploy", "publish", "release", "write"].contains { lower.contains($0) }
    }

    /// Options that do not change what a script runs. Anything else in front of `--` (for example
    /// `--script-shell=…`, `--prefix …`, `--node-options=…`) makes a "low" package-manager call review.
    private static let harmlessNodeFlags: Set<String> = [
        "--silent", "-s", "--quiet", "-q", "--verbose", "--if-present", "--watch", "--no-watch", "--coverage", "--ci",
        "--bail", "--color", "--no-color", "--run", "--runInBand", "--passWithNoTests", "--watchAll=false",
        "--version", "-v", "--help", "-h", "--workspaces", "-ws", "--json", "--long", "--all", "-a", "--depth=0",
    ]

    private func nodePackageManager(_ name: String, _ args: [String], paths: [String]) -> CommandResult {
        var result = nodePackageManagerCommand(name, args, paths: paths)
        let own = args.prefix { $0 != "--" }.filter { $0.hasPrefix("-") }
        if result.verdict.level == .low, own.contains(where: { !Self.harmlessNodeFlags.contains($0) }) {
            result.verdict = review(reasons: [Reason.customOptions])
        }
        return result
    }

    private func nodePackageManagerCommand(_ name: String, _ args: [String], paths: [String]) -> CommandResult {
        guard let sub = Self.firstNonFlag(args) else {
            // A bare `yarn` installs; bare npm/pnpm/bun print help.
            return CommandResult(verdict: name == "yarn" ? installVerdict("install") : low())
        }
        let rest = Array(args.drop { $0 != sub }.dropFirst())
        if ["test", "t", "tst"].contains(sub) { return CommandResult(verdict: low(), paths: paths) }
        if sub == "run" || sub == "run-script" {
            guard let script = Self.firstNonFlag(rest) else { return CommandResult(verdict: low()) }
            return CommandResult(verdict: Self.isLowScript(script) ? low() : review(reasons: ["Runs a project script"]), paths: paths)
        }
        if name != "npm", Self.isLowScript(sub) { return CommandResult(verdict: low(), paths: paths) }
        if ["exec", "x", "dlx"].contains(sub) { return CommandResult(verdict: review(reasons: [Reason.network, "Runs a package"]), paths: paths) }
        if Self.installVerbs.contains(sub) || Self.removeVerbs.contains(sub) { return CommandResult(verdict: installVerdict(sub), paths: paths) }
        if ["ls", "list", "outdated", "view", "info", "why", "help", "--version", "-v"].contains(sub) {
            return CommandResult(verdict: low(), paths: paths)
        }
        if sub == "publish" { return CommandResult(verdict: review(title: "Publish a package", reasons: [Reason.network]), paths: paths) }
        return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
    }

    private static let installVerbs: Set<String> = [
        "install", "i", "ci", "add", "update", "up", "upgrade", "link", "dedupe", "prune", "sync", "reinstall",
        "tap", "get", "require", "download", "it", "install-test", "isntall", "lock", "deps.get", "bundle", "resolve",
    ]
    private static let removeVerbs: Set<String> = ["uninstall", "remove", "rm", "un", "r", "purge"]

    private func packageManager(_ args: [String], paths: [String]) -> CommandResult {
        let sub = Self.firstNonFlag(args) ?? ""
        if Self.installVerbs.contains(sub) || Self.removeVerbs.contains(sub) {
            return CommandResult(verdict: installVerdict(sub), paths: paths)
        }
        return CommandResult(verdict: review(reasons: [Reason.unfamiliar]), paths: paths)
    }

    private func installVerdict(_ verb: String) -> BashVerdict {
        review(title: Self.removeVerbs.contains(verb) ? "Remove packages" : "Install packages",
               reasons: [Reason.network, Reason.dependencies])
    }

    private func make(_ args: [String]) -> CommandResult {
        var targets: [String] = []
        var paths: [String] = []
        var custom = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if ["-C", "-f", "--directory", "--file", "--makefile", "-I"].contains(a) {
                if i + 1 < args.count { paths.append(args[i + 1]) }
                i += 2; continue
            }
            if a == "-j" || a == "-l" {
                i += (i + 1 < args.count && Int(args[i + 1]) != nil) ? 2 : 1
                continue
            }
            // `SHELL=./x`, `CC=./x` and `--eval=…` change what the targets run.
            if Self.isAssignment(a) || a.hasPrefix("--eval") || a == "-E" { custom = true; i += 1; continue }
            if a.hasPrefix("-") { i += 1; continue }
            targets.append(a)
            i += 1
        }
        // A bare `make` runs whatever the default target is.
        let safe = !custom && !targets.isEmpty && targets.allSatisfy { ["test", "build"].contains($0) }
        return CommandResult(verdict: safe ? low() : review(reasons: [Reason.unfamiliar]), paths: paths)
    }

    private func download(_ name: String, _ args: [String]) -> CommandResult {
        var writes: [String] = []
        var reads: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "-o", "--output", "--output-document":
                if let n = next, n != "-" { writes.append(n) }
                i += 2; continue
            case "-O" where name == "wget":
                if let n = next, n != "-" { writes.append(n) }
                i += 2; continue
            case "-T", "--upload-file":
                if let n = next { reads.append(n) }
                i += 2; continue
            case "-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form":
                if let n = next, let at = n.firstIndex(of: "@") { reads.append(String(n[n.index(after: at)...])) }
                i += 2; continue
            default:
                if a.hasPrefix("--output="), let eq = a.firstIndex(of: "=") { writes.append(String(a[a.index(after: eq)...])) }
                if a.hasPrefix("--output-document="), let eq = a.firstIndex(of: "=") { writes.append(String(a[a.index(after: eq)...])) }
                i += 1
            }
        }
        let pos = Self.positional(args)
        let host = (pos.first { $0.contains("://") } ?? pos.first { !$0.contains(" ") && !$0.contains("@") })
            .flatMap(TextKit.host(of:))
        let v = review(title: host.map { "Fetch \($0)" }, reasons: [Reason.network])
        return CommandResult(verdict: v, paths: reads, written: writes)
    }

    private func rm(_ args: [String], _ ctx: Context) -> CommandResult {
        var recursive = false
        var targets: [String] = []
        var afterDoubleDash = false
        for a in args {
            if afterDoubleDash { targets.append(a); continue }
            if a == "--" { afterDoubleDash = true; continue }
            if a == "--recursive" { recursive = true; continue }
            if a.hasPrefix("--") { continue }
            if a.hasPrefix("-"), a.count > 1 {
                if a.contains("r") || a.contains("R") { recursive = true }
                continue
            }
            targets.append(a)
        }
        let outside = targets.contains { leaves($0, ctx) }
        let reason = outside ? Reason.notInGit : Reason.cantUndo
        if recursive {
            return CommandResult(verdict: BashVerdict(level: .high, title: outside ? "Delete files outside this repo" : "Delete files",
                                                      reasons: [reason]),
                                 paths: targets)
        }
        let title: String
        if targets.count == 1, Self.isPathWord(targets[0]), !targets[0].contains("$") {
            title = "Delete \(LexicalPath.lastComponent(targets[0]))"
        } else {
            title = "Delete files"
        }
        return CommandResult(verdict: review(title: title, reasons: [reason]), paths: targets)
    }

    private func permissions(_ name: String, _ args: [String]) -> CommandResult {
        let recursive = args.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("R")) }
        let files = Array(Self.positional(args).dropFirst())  // the first positional is the mode or owner
        let what = name == "chmod" ? "permissions" : "ownership"
        if recursive {
            return CommandResult(verdict: BashVerdict(level: .high, title: "Change \(what) recursively", reasons: ["Recursive"]), paths: files)
        }
        return CommandResult(verdict: review(reasons: ["Changes \(what)"]), paths: files)
    }

    private func formatVerdict() -> BashVerdict {
        BashVerdict(level: .high, title: "Format a disk", reasons: ["Erases a disk", Reason.cantUndo])
    }

    // MARK: - Verdict helpers

    private func low() -> BashVerdict { BashVerdict(level: .low, reasons: [Reason.readOnly]) }

    private func review(title: String? = nil, reasons: [String]) -> BashVerdict {
        BashVerdict(level: .review, title: title, reasons: reasons)
    }

    // MARK: - Paths

    func resolve(_ word: String, _ ctx: Context) -> String {
        LexicalPath.resolve(word, base: ctx.cwd, home: home)
    }

    /// The resolved path lies outside the project (never when the project is unknown).
    func leavesRoot(_ resolved: String) -> Bool {
        !root.isEmpty && resolved.hasPrefix("/") && !LexicalPath.isInside(resolved, root: root)
    }

    func leaves(_ word: String, _ ctx: Context) -> Bool {
        guard Self.isPathWord(word) else { return false }
        let p = resolve(word, ctx)
        return !LexicalPath.isExemptDevice(p) && leavesRoot(p)
    }

    static func isPathWord(_ w: String) -> Bool {
        !w.isEmpty && w != "-" && !w.contains("://") && !w.contains(ShellParser.substitutionWord)
    }

    // MARK: - Word helpers

    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "which", "whereis", "file", "stat", "du", "df", "tree", "sort",
        "uniq", "cut", "tr", "diff", "cmp", "basename", "dirname", "realpath", "readlink", "uname", "hostname", "id",
        "whoami", "date", "printenv", "type", "command", "less", "more", "nl", "column", "sleep", "test", "[", "true",
        "false", "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "bat", "fd", "exa", "eza", "comm", "paste", "fold",
        "rev", "xxd", "hexdump", "od", "strings", "lsof", "ps", "top", "uptime", "sw_vers", "groups", "locale", "tty",
        "env", "cal", "seq", "yes", "expr", "wait",
    ]

    static let downloaders: Set<String> = ["curl", "wget", "http", "https", "aria2c"]
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python2", "python3", "node", "perl", "ruby", "php",
        "eval", "source", ".", "deno", "bun", "osascript",
    ]

    static func commandName(_ word: String) -> String { LexicalPath.lastComponent(word) }

    static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        var name = w[..<eq]
        if name.hasSuffix("+") { name = name.dropLast() }
        guard let f = name.first, f.isLetter || f == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Non-flag arguments, plus the values of `--flag=value`. Everything after `--` is positional.
    static func positional(_ args: [String]) -> [String] {
        var out: [String] = []
        var afterDoubleDash = false
        for a in args {
            if afterDoubleDash { out.append(a); continue }
            if a == "--" { afterDoubleDash = true; continue }
            if a.hasPrefix("-"), a.count > 1 {
                if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") { out.append(String(a[a.index(after: eq)...])) }
                continue
            }
            out.append(a)
        }
        return out
    }

    /// Non-flag arguments, skipping the values of `valueFlags` (`uniq -f 2 in out` -> ["in", "out"]).
    static func operands(_ args: [String], valueFlags: Set<String>) -> [String] {
        var out: [String] = []
        var i = 0
        var afterDoubleDash = false
        while i < args.count {
            let a = args[i]
            i += 1
            if afterDoubleDash { out.append(a); continue }
            if a == "--" { afterDoubleDash = true; continue }
            if valueFlags.contains(a) { i += 1; continue }
            if a.hasPrefix("-"), a.count > 1 { continue }
            out.append(a)
        }
        return out
    }

    /// Variables that only switch a mode: setting them in front of a command does not change what runs.
    private static let harmlessVariables: Set<String> = [
        "NODE_ENV", "CI", "DEBUG", "FORCE_COLOR", "NO_COLOR", "COLOR", "CLICOLOR", "CLICOLOR_FORCE", "TERM", "TZ",
        "LANG", "LANGUAGE", "RAILS_ENV", "RACK_ENV", "APP_ENV", "ENVIRONMENT", "PORT", "HOST", "LOG_LEVEL", "VERBOSE",
        "RUST_BACKTRACE", "PYTHONUNBUFFERED", "PYTHONDONTWRITEBYTECODE", "CGO_ENABLED", "GOOS", "GOARCH", "COLUMNS",
        "LINES", "TEST_ENV", "UPDATE_SNAPSHOTS",
    ]

    private static func variableName(_ assignment: String) -> String {
        var name = assignment.prefix { $0 != "=" }
        if name.hasSuffix("+") { name = name.dropLast() }
        return String(name)
    }

    /// `VAR=value command`: anything but a known mode switch may change which program runs or how
    /// (PATH, GIT_EXTERNAL_DIFF, DYLD_INSERT_LIBRARIES, NODE_OPTIONS, npm_config_script_shell, ...).
    static func isRiskyEnvironment(_ assignment: String) -> Bool {
        let name = variableName(assignment)
        return !harmlessVariables.contains(name) && !name.hasPrefix("LC_")
    }

    /// A bare `VAR=value` (no command): lower-case names are script locals; the rest is treated like
    /// an environment change for the commands that follow.
    static func isRiskyShellVariable(_ assignment: String) -> Bool {
        let name = variableName(assignment)
        guard isRiskyEnvironment(assignment) else { return false }
        if name.lowercased().hasPrefix("npm_config") { return true }
        return !name.contains(where: \.isLowercase)
    }

    static func firstNonFlag(_ args: [String]) -> String? {
        args.first { !$0.hasPrefix("-") }
    }

    /// Positional arguments without the leading pattern/script (unless one was given by flag).
    static func dropPattern(_ args: [String], patternFlags: Set<String>) -> [String] {
        let pos = positional(args)
        let byFlag = args.contains { a in patternFlags.contains(a) || patternFlags.contains { a.hasPrefix($0 + "=") } }
        return byFlag ? pos : Array(pos.dropFirst())
    }

    private static let leadingKeywords: Set<String> = ["if", "then", "elif", "else", "do", "while", "until", "!", "{", "}", "time"]
    private static let headerKeywords: Set<String> = ["fi", "done", "esac", "for", "case", "select", "function", "in", ";;"]

    /// Drops shell keywords in front of a command; loop and case headers are not commands.
    static func stripKeywords(_ words: [String]) -> [String] {
        var w = words[...]
        while let f = w.first, leadingKeywords.contains(f) { w = w.dropFirst() }
        if let f = w.first, headerKeywords.contains(f) { return [] }
        return Array(w)
    }

    /// Removes leading assignments and wrappers (`sudo`, `env`, `nohup`, `xargs`, ...).
    /// `env` is true when an assignment or an `env` option may change which program runs
    /// (see `isRiskyEnvironment`). `env -S "cmd args"` is replaced by the words of its string.
    static func unwrap(_ words: [String]) -> (words: [String], sudo: Bool, env: Bool) {
        var w = words[...]
        var sudo = false
        var env = false
        loop: while true {
            while let f = w.first, isAssignment(f) {
                if isRiskyEnvironment(f) { env = true }
                w = w.dropFirst()
            }
            guard let f = w.first else { break }
            switch commandName(f) {
            case "sudo", "doas", "run0":
                sudo = true
                w = w.dropFirst()
                while let g = w.first, g.hasPrefix("-") {
                    if g == "--" { w = w.dropFirst(); break }
                    let takesValue = ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"].contains(g)
                    w = w.dropFirst(takesValue ? 2 : 1)
                }
            case "env":
                let rest = Array(w.dropFirst())
                var split: [String] = []
                var risky = false
                var i = 0
                scan: while i < rest.count {
                    let g = rest[i]
                    if g == "--" { i += 1; break scan }
                    if g == "-S" || g == "--split-string" {
                        // `env -S 'cmd args'` runs cmd: read the string as the command it is.
                        if i + 1 < rest.count { split = splitString(rest[i + 1]) }
                        risky = true
                        i += 2
                        break scan
                    }
                    if g.hasPrefix("--split-string=") || (g.hasPrefix("-S") && g.count > 2) {
                        split = splitString(String(g.dropFirst(g.hasPrefix("--") ? "--split-string=".count : 2)))
                        risky = true
                        i += 1
                        break scan
                    }
                    if ["-u", "--unset"].contains(g) { i += 2; continue }
                    if ["-C", "--chdir", "-P"].contains(g) { risky = true; i += 2; continue }
                    if g.hasPrefix("-") {
                        // A cluster such as `-iS` hides a split string: do not try to parse it.
                        if !g.hasPrefix("--"), g.contains("S") || g.contains("P") || g.contains("C") { risky = true }
                        i += 1
                        continue
                    }
                    if isAssignment(g) {
                        if isRiskyEnvironment(g) { risky = true }
                        i += 1
                        continue
                    }
                    break scan
                }
                let remaining = split + rest[min(i, rest.count)...]
                guard !remaining.isEmpty else { break loop }  // a bare `env` prints the environment
                if risky { env = true }
                w = remaining[...]
            case "command":
                if let next = w.dropFirst().first, next == "-v" || next == "-V" { break loop }
                w = w.dropFirst()
                while let g = w.first, g.hasPrefix("-") { w = w.dropFirst() }
            case "builtin", "exec", "nohup", "time", "caffeinate", "stdbuf":
                w = w.dropFirst()
                while let g = w.first, g.hasPrefix("-") { w = w.dropFirst() }
            case "nice":
                w = w.dropFirst()
                if w.first == "-n" { w = w.dropFirst(2) }
                while let g = w.first, g.hasPrefix("-") { w = w.dropFirst() }
            case "timeout", "gtimeout":
                w = w.dropFirst()
                while let g = w.first, g.hasPrefix("-") { w = w.dropFirst(["-s", "-k", "--signal", "--kill-after"].contains(g) ? 2 : 1) }
                w = w.dropFirst()  // the duration
            case "xargs":
                w = w.dropFirst()
                while let g = w.first, g.hasPrefix("-") {
                    w = w.dropFirst(["-I", "-n", "-P", "-L", "-d", "-s", "-E", "-a", "-J", "-R", "-S"].contains(g) ? 2 : 1)
                }
            default:
                break loop
            }
        }
        return (Array(w), sudo, env)
    }

    /// The words of an `env -S` string: split on whitespace, quotes dropped.
    private static func splitString(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.filter { $0 != "\"" && $0 != "'" } }
            .filter { !$0.isEmpty }
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - Remote scripts

    private static func name(of seg: ShellSegment) -> String {
        unwrap(stripKeywords(seg.words)).words.first.map(commandName) ?? ""
    }

    private static func containsDownloader(_ segments: [ShellSegment]) -> Bool {
        segments.contains { downloaders.contains(name(of: $0)) || $0.substitutions.contains(where: containsDownloader) }
    }

    /// Base names of the files a `curl`/`wget` segment saves: `-o X`, `--output X`, wget `-O X`,
    /// the URL's file name for `curl -O` and plain `wget URL`, and `> X` redirects.
    private static func downloadedFiles(_ seg: ShellSegment) -> [String] {
        let words = unwrap(stripKeywords(seg.words)).words
        guard let first = words.first, downloaders.contains(commandName(first)) else { return [] }
        let isWget = commandName(first) == "wget"
        var out: [String] = []
        var namedByURL = isWget
        var i = 1
        while i < words.count {
            let a = words[i]
            if ["-o", "--output", "--output-document"].contains(a) || (isWget && a == "-O") {
                if i + 1 < words.count, words[i + 1] != "-" { out.append(words[i + 1]) }
                if isWget, a != "-o" { namedByURL = false }
                i += 2
                continue
            }
            if !isWget, a == "--remote-name" || (a.hasPrefix("-") && !a.hasPrefix("--") && a.contains("O")) { namedByURL = true }
            if isWget, a.hasPrefix("-"), !a.hasPrefix("--"), a.contains("O") { namedByURL = false }  // -qO- etc.
            i += 1
        }
        if namedByURL {
            for w in words where w.contains("://") {
                if let name = URLComponents(string: w)?.path.split(separator: "/").last { out.append(String(name)) }
            }
        }
        out += seg.redirects.filter(\.writes).compactMap(\.target)
        return out.map(commandName)
    }

    /// `curl … | sh`, `bash -c "$(curl …)"`, `bash <(curl …)`, `eval "$(wget …)"`,
    /// and `curl -o x.sh … && bash x.sh` (a downloaded file run later in the same command).
    static func runsRemoteScript(_ segments: [ShellSegment]) -> Bool {
        var downloaded = Set<String>()
        for s in segments {
            let words = unwrap(stripKeywords(s.words)).words
            if let first = words.first, !downloaded.isEmpty {
                let name = commandName(first)
                if downloaded.contains(name), first.contains("/") { return true }  // ./install.sh
                if interpreters.contains(name), words.dropFirst().contains(where: { downloaded.contains(commandName($0)) }) {
                    return true
                }
            }
            downloaded.formUnion(downloadedFiles(s))
        }
        var i = 0
        while i < segments.count {
            var j = i
            while j + 1 < segments.count, segments[j + 1].pipeline == segments[i].pipeline { j += 1 }
            let names = segments[i...j].map(name(of:))
            if let d = names.firstIndex(where: downloaders.contains),
               names[(d + 1)...].contains(where: interpreters.contains) {
                return true
            }
            i = j + 1
        }
        for s in segments {
            if interpreters.contains(name(of: s)), s.substitutions.contains(where: containsDownloader) { return true }
            if s.substitutions.contains(where: runsRemoteScript) { return true }
        }
        return false
    }
}
