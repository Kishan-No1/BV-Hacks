// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import NotchAgentCore

/// Command-line options: `--demo`, `--demo-http`, `--snapshot DIR`, `--version`; `NOTCH_AGENT_PORT`, `NOTCH_AGENT_RULES_FILE`,
/// `NOTCH_AGENT_STYLE_FILE`, `NOTCH_AGENT_APPROVALS_FILE` and `NOTCH_AGENT_PANES_DIR` env.
struct LaunchOptions: Equatable {
    var demo = false
    var demoHTTP = false
    var snapshotDir: String?
    var version = false
    var port: UInt16 = HookServer.defaultPort
    /// TEST ONLY (`--test-autodecide MODE`): answer every request shown in the island without a human.
    var autoDecide: AutoDecideMode?
    /// Rules file override (`NOTCH_AGENT_RULES_FILE`), so tests never touch the real rules.
    var rulesFile: String?
    /// Style profile override (`NOTCH_AGENT_STYLE_FILE`), so tests never touch the real learned style.
    var styleFile: String?
    /// Learned approval model override (`NOTCH_AGENT_APPROVALS_FILE`), so tests never train the real model.
    var approvalsFile: String?
    /// Pane records override (`NOTCH_AGENT_PANES_DIR`): where `scripts/notch-agent-claude` wrote its session -> pane files.
    var panesDir: String?
    /// TEST ONLY (`--test-compose TEXT`): drive the composer without a human. Polishes with the offline stub
    /// (never the network) and presses Send through the same model actions as the buttons.
    var testCompose: String?
    var errors: [String] = []

    static func parse(_ args: [String], env: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--demo": o.demo = true
            case "--demo-http": o.demo = true; o.demoHTTP = true
            case "--version", "-v": o.version = true
            case "--snapshot":
                if i + 1 < args.count { o.snapshotDir = args[i + 1]; i += 1 } else { o.errors.append("--snapshot needs a directory") }
            case "--test-autodecide":
                if i + 1 < args.count, let m = AutoDecideMode(rawValue: args[i + 1]) { o.autoDecide = m; i += 1 } else {
                    o.errors.append("--test-autodecide needs one of: default, allow, deny, always")
                }
            case "--test-compose":
                if i + 1 < args.count, !args[i + 1].isEmpty { o.testCompose = args[i + 1]; i += 1 } else {
                    o.errors.append("--test-compose needs the prompt text")
                }
            default:
                if a.hasPrefix("--snapshot=") { o.snapshotDir = String(a.dropFirst("--snapshot=".count)) }
                // Ignore other arguments (Xcode / launch services may pass -NS... flags).
            }
            i += 1
        }
        if let p = env["NOTCH_AGENT_PORT"], !p.isEmpty {
            if let port = UInt16(p), port > 0 { o.port = port } else { o.errors.append("NOTCH_AGENT_PORT=\(p) is not a valid port") }
        }
        if let f = env["NOTCH_AGENT_RULES_FILE"], !f.isEmpty { o.rulesFile = f }
        if let f = env["NOTCH_AGENT_STYLE_FILE"], !f.isEmpty { o.styleFile = f }
        if let f = env["NOTCH_AGENT_APPROVALS_FILE"], !f.isEmpty { o.approvalsFile = f }
        if let d = env["NOTCH_AGENT_PANES_DIR"], !d.isEmpty { o.panesDir = d }
        return o
    }
}

/// What `--test-autodecide` does with each request, through the same model actions as the buttons and hotkeys.
enum AutoDecideMode: String, Equatable {
    /// The default action (what Option-Return does): allow low/review, deny high.
    case `default`
    case allow
    case deny
    /// "Always allow" (saves the suggested rule when there is one).
    case always
}

@main
enum NotchAgentMain {
    static let version = "0.1.0"
    /// Keeps the app delegate alive (NSApplication.delegate is weak).
    @MainActor static var controller: AppController?

    @MainActor
    static func main() {
        let options = LaunchOptions.parse(CommandLine.arguments, env: ProcessInfo.processInfo.environment)
        if options.version {
            print("notchAgent \(version)")
            return
        }
        for e in options.errors { Log.info(e) }

        let app = NSApplication.shared
        if let dir = options.snapshotDir {
            // Offscreen only: no panel, no Dock icon, no screen-recording permission needed.
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let ok = await Snapshotter.run(directory: dir)
                exit(ok ? 0 : 1)
            }
            app.run()
            return
        }

        // One island only: the login item and a manual `open` must never both draw one.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier, !options.demo,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            Log.info("notchAgent is already running; exiting")
            return
        }

        if LegacyData.migrate() { Log.info("moved ~/Library/Application Support/Nod to notchAgent (the app was renamed)") }
        let controller = AppController(options: options)
        self.controller = controller
        app.delegate = controller
        app.run()
    }
}
