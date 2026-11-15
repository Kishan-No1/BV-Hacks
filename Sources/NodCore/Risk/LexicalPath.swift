// OWNER: workstream A (core-logic).
import Foundation

/// Lexical path helpers. Nothing here touches the disk: `~`, `$HOME`, `.` and `..` are resolved as text.
enum LexicalPath {
    /// Collapses `.`, `..`, repeated and trailing slashes. "" stays "". Relative input stays relative.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !absolute { parts.append(comp) }
                continue
            }
            parts.append(comp)
        }
        let joined = parts.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// Expands a leading `~`, `$HOME` or `${HOME}` and makes the path absolute against `base`.
    /// When `base` is "" a relative path stays relative (normalized).
    static func resolve(_ raw: String, base: String, home: String) -> String {
        var p = raw
        if p == "~" || p.hasPrefix("~/") {
            p = home + p.dropFirst()
        } else if p.hasPrefix("~") {
            // ~otheruser/...: a sibling of the home folder.
            let parent = (home as NSString).deletingLastPathComponent
            p = parent + "/" + p.dropFirst()
        } else if p == "$HOME" || p.hasPrefix("$HOME/") {
            p = home + p.dropFirst(5)
        } else if p == "${HOME}" || p.hasPrefix("${HOME}/") {
            p = home + p.dropFirst(7)
        }
        if !p.hasPrefix("/") && !base.isEmpty {
            p = base + "/" + p
        }
        return normalize(p)
    }

    /// True when `path` (absolute, normalized) is `root` or below it.
    static func isInside(_ path: String, root: String) -> Bool {
        let r = normalize(root)
        guard !r.isEmpty else { return true }
        if r == "/" { return true }
        return path == r || path.hasPrefix(r + "/")
    }

    /// Repo-relative display text: "src/auth/session.ts" inside `root`, nil outside it.
    static func relative(_ path: String, to root: String) -> String? {
        let r = normalize(root)
        guard !r.isEmpty, isInside(path, root: r) else { return nil }
        if path == r { return "." }
        if r == "/" { return String(path.dropFirst()) }
        return String(path.dropFirst(r.count + 1))
    }

    static func lastComponent(_ path: String) -> String {
        let n = normalize(path)
        if n == "/" || n.isEmpty { return n }
        return n.split(separator: "/").last.map(String.init) ?? n
    }

    /// `~/x` for paths under the home folder, the absolute path otherwise.
    static func abbreviated(_ path: String, home: String) -> String {
        if !home.isEmpty, home != "/", isInside(path, root: home) {
            return path == home ? "~" : "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Device files that are safe to name anywhere (`2>/dev/null`).
    static func isExemptDevice(_ path: String) -> Bool {
        ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty", "/dev/zero", "/dev/random", "/dev/urandom"]
            .contains(path) || path.hasPrefix("/dev/fd/")
    }

    /// Secrets and credentials: `.env*`, anything under a `.ssh` folder, `.claude/settings*`,
    /// `*.pem`, `*.key`, ssh private keys (`id_rsa*`, `id_ed25519*`, ...), keychains, `.aws`, `.netrc`,
    /// `.npmrc`, `.pypirc`, `.docker/config.json`, `gh/hosts.yml`, shell history.
    /// Checked by path components, so it works for any home folder.
    static func isSensitive(_ path: String) -> Bool {
        let comps = normalize(path).split(separator: "/").map { String($0).lowercased() }
        guard let name = comps.last else { return false }
        if name.hasPrefix(".env") { return true }
        if comps.dropLast().contains(".ssh") { return true }
        if name == ".ssh" { return true }
        if comps.count >= 2, comps[comps.count - 2] == ".claude", name.hasPrefix("settings") { return true }
        if name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasSuffix(".p12") { return true }
        for key in ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"] where name.hasPrefix(key) { return true }
        if name.contains(".keychain") || comps.contains("keychains") { return true }
        // Other credential stores and shell history.
        let dirs = comps.dropLast()
        if dirs.contains(".aws") || dirs.contains(".gnupg") || name == ".aws" || name == ".gnupg" { return true }
        if [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass"].contains(name) { return true }
        if name.hasPrefix("."), name.hasSuffix("_history") { return true }  // .zsh_history, .bash_history, ...
        let parent = dirs.last ?? ""
        if (parent == ".docker" && name == "config.json") || (parent == "gh" && name == "hosts.yml")
            || (parent == ".kube" && name == "config") { return true }
        return false
    }

    /// Files that make later commands run code: anything under `.git/` (hooks, config) or `.claude/`
    /// (settings, hooks, commands), and `.mcp.json`. Writing one is high risk and never gets an
    /// always-allow rule.
    static func isCodeConfig(_ path: String) -> Bool {
        let comps = normalize(path).split(separator: "/").map { String($0).lowercased() }
        guard let name = comps.last else { return false }
        if name == ".mcp.json" { return true }
        let dirs = comps.dropLast()
        return dirs.contains(".git") || dirs.contains(".claude")
    }

    /// Words that could name a path outside the project: absolute, `~` or `$HOME` based, or containing `..`.
    /// Relative paths without `..` always stay inside, so they never need resolving for the outside check.
    static func mayLeave(_ word: String) -> Bool {
        if word.contains("://") { return false }
        if word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix("$HOME") || word.hasPrefix("${HOME}") { return true }
        return word.split(separator: "/", omittingEmptySubsequences: false).contains("..") || word == ".."
    }
}
