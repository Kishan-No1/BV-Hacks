// OWNER: workstream C (app-ui).
import AppKit
import Foundation

/// "Install Claude Code hooks…": the ONLY code path that may touch the user's real `~/.claude/settings.json`.
/// It runs `scripts/install-hooks.sh` (which backs the file up first) and only after an explicit confirmation.
@MainActor
enum HookInstaller {
    /// Candidate roots: the app bundle's Resources, the working directory, and the repo above `.build/<x>/<config>/Nod`.
    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        if let res = Bundle.main.resourceURL { roots.append(res) }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            roots.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        return roots
    }

    static func locate(_ relativePath: String) -> URL? {
        for root in candidateRoots() {
            let url = root.appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: url.path) || FileManager.default.fileExists(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    static func confirmAndInstall() {
        guard let script = locate("scripts/install-hooks.sh") else {
            alert(title: "Install script not found",
                  text: "Nod could not find scripts/install-hooks.sh in the app bundle or the current directory.")
            return
        }
        let hook = locate("hooks/nod-hook.sh")
        NSApp.activate()
        let confirm = NSAlert()
        confirm.messageText = "Install Claude Code hooks?"
        confirm.informativeText = """
        Nod will add its hooks to ~/.claude/settings.json so Claude Code sessions show up in the notch and can ask \
        you for permission there. A timestamped backup of the file is written first.

        Script: \(script.path)\(hook.map { "\nHook: \($0.path)" } ?? "")
        """
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        var args = [script.path]
        if let hook { args += ["--hook", hook.path] }
        Log.info("install-hooks: running \(args.joined(separator: " "))")
        Task.detached {
            let (status, output) = Self.run("/bin/bash", args)
            await MainActor.run {
                alert(title: status == 0 ? "Hooks installed" : "Installing hooks failed (exit \(status))",
                      text: output.isEmpty ? "(no output)" : String(output.suffix(4000)))
            }
        }
    }

    nonisolated static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // terminationHandler, not waitUntilExit(): the latter can hang on a GCD thread after the child exited.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            return (-1, "Could not start: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func alert(title: String, text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
