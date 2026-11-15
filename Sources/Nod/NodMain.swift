// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import NodCore

/// Command-line options: `--demo`, `--demo-http`, `--snapshot DIR`, `--version`; `NOD_PORT` env.
struct LaunchOptions: Equatable {
    var demo = false
    var demoHTTP = false
    var snapshotDir: String?
    var version = false
    var port: UInt16 = HookServer.defaultPort
    /// TEST ONLY (`--test-autodecide MODE`): answer every request shown in the island without a human.
    var autoDecide: AutoDecideMode?
    /// Rules file override (`NOD_RULES_FILE`), so tests never touch the real rules.
    var rulesFile: String?
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
            default:
                if a.hasPrefix("--snapshot=") { o.snapshotDir = String(a.dropFirst("--snapshot=".count)) }
                // Ignore other arguments (Xcode / launch services may pass -NS... flags).
            }
            i += 1
        }
        if let p = env["NOD_PORT"], !p.isEmpty {
            if let port = UInt16(p), port > 0 { o.port = port } else { o.errors.append("NOD_PORT=\(p) is not a valid port") }
        }
        if let f = env["NOD_RULES_FILE"], !f.isEmpty { o.rulesFile = f }
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
enum NodMain {
    static let version = "0.1.0"
    /// Keeps the app delegate alive (NSApplication.delegate is weak).
    @MainActor static var controller: AppController?

    @MainActor
    static func main() {
        let options = LaunchOptions.parse(CommandLine.arguments, env: ProcessInfo.processInfo.environment)
        if options.version {
            print("Nod \(version)")
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

        let controller = AppController(options: options)
        self.controller = controller
        app.delegate = controller
        app.run()
    }
}
