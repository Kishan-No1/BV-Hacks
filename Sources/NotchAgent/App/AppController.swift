// OWNER: workstream C (app-ui).
import AppKit
import NotchAgentCore
import SwiftUI

/// The menu-bar agent: hook server + store, the notch panel, hotkeys, the status item, demo mode.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum ServerState {
        case starting
        case on(UInt16)
        case off(String)
    }

    let options: LaunchOptions
    let rules: RulesStore
    /// The learned approval model: a chip on each request card, trained by each Allow or Deny in the island.
    let approvals: ApprovalModelStore
    let approvalsURL: URL
    let liveStore: SessionStore
    let server: HookServer
    let model: IslandModel
    /// The composer's services: learned style, polish, tmux send.
    let composerWiring: ComposerWiring
    private(set) var serverState: ServerState = .starting

    private var panel: NotchPanelController?
    private var hotkeys: HotkeyController?
    private var registrar: CarbonHotkeyRegistrar?
    private var statusItem: NSStatusItem?
    private var demoTask: Task<Void, Never>?
    private var autoDecideLoop: ObservationLoop<UUID?>?
    private var composeHotkey: GlobalHotkey?
    private var testComposeLoop: ObservationLoop<String?>?
    private let polishItem = NSMenuItem(title: "Polish prompts with Claude Haiku", action: nil, keyEquivalent: "")
    private var activity: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let serverItem = NSMenuItem(title: "Hook server: starting…", action: nil, keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Auto-allowed: 0", action: nil, keyEquivalent: "")
    private let learnedItem = NSMenuItem(title: "Learned from 0 decisions", action: nil, keyEquivalent: "")
    private let demoItem = NSMenuItem(title: "Play demo", action: nil, keyEquivalent: "")

    init(options: LaunchOptions) {
        self.options = options
        rules = RulesStore(fileURL: options.rulesFile.map { URL(fileURLWithPath: $0) } ?? RulesStore.defaultFileURL)
        approvalsURL = options.approvalsFile.map { URL(fileURLWithPath: $0) } ?? ApprovalModelStore.defaultFileURL
        approvals = ApprovalModelStore(fileURL: approvalsURL)
        liveStore = SessionStore(rules: rules, approvals: approvals)
        server = HookServer(port: options.port, handler: liveStore.hookHandler())
        model = IslandModel(store: liveStore)
        composerWiring = ComposerWiring(options: options)
        super.init()
        composerWiring.install(on: model.composer)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A held permission request must be answered promptly even when the panel is occluded or the app
        // has been idle: keep App Nap from throttling the server and the timers.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Answering Claude Code permission requests")
        setupStatusItem()

        let panel = NotchPanelController(model: model)
        self.panel = panel
        model.start()
        panel.show()
        // Switching to the app a session runs in (e.g. from an alert) puts that session's cards away.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.model.appActivated(pid: pid) }
        }

        let registrar = CarbonHotkeyRegistrar()
        registrar.onPress = { [weak self] key in
            MainActor.assumeIsolated { self?.handleHotkey(key) }
        }
        self.registrar = registrar
        let hotkeys = HotkeyController(registrar: registrar) { [weak self] in
            guard let self else { return false }
            return !self.model.store.pending.isEmpty
        }
        self.hotkeys = hotkeys
        hotkeys.start()

        let composeHotkey = GlobalHotkey()
        composeHotkey.onPress = { [weak self] in
            MainActor.assumeIsolated {
                Log.debug("hotkey: \(GlobalHotkey.composeLabel) (composer)")
                self?.model.toggleComposer()
            }
        }
        composeHotkey.register()
        self.composeHotkey = composeHotkey

        startAutoDecideIfAsked()
        startTestComposeIfAsked()
        startServer()
        startPruning()
        Log.info("notchAgent \(NotchAgentMain.version) running (hook port \(options.port))\(options.demo ? ", demo mode" : "")")

        if options.demo {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.playDemo()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        demoTask?.cancel()
        hotkeys?.stop()
        composeHotkey?.unregister()
        server.stop()
        panel?.close()
    }

    // MARK: Server

    /// Every few seconds, drops sessions whose Claude Code process is gone so the notch only shows
    /// agents that are still running.
    private func startPruning() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.liveStore.pruneEndedSessions()
            }
        }
    }

    private func startServer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let port = try await self.server.start()
                self.serverState = .on(port)
                Log.info("hook server listening on 127.0.0.1:\(port)")
            } catch {
                self.serverState = .off("\(error)")
                Log.info("hook server failed to start (\(error)); running with the hook server off")
            }
            self.refreshMenu()
        }
    }

    // MARK: Test-only auto-decide

    /// `--test-autodecide MODE`: answers each request a moment after the island shows it, through the same
    /// `IslandModel` actions as the buttons and hotkeys. Off unless the flag is passed.
    private func startAutoDecideIfAsked() {
        guard let mode = options.autoDecide else { return }
        let env = ProcessInfo.processInfo.environment
        let delay = max(0, Double(env["NOTCH_AGENT_TEST_DECIDE_DELAY"] ?? "") ?? 0.4)
        Log.info("TEST MODE: auto-deciding every request (\(mode.rawValue)) after \(delay)s")
        let loop = ObservationLoop<UUID?>({ [weak self] in self?.model.store.currentRequest?.id }) { [weak self] id in
            guard let id else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, let r = self.model.store.currentRequest, r.id == id else { return }
                Log.info("TEST MODE: \(mode.rawValue) -> \(r.toolName) [\(r.assessment.level.label)] \(r.assessment.title)")
                switch mode {
                case .default: self.model.performDefault()
                case .allow: self.model.allow(id)
                case .deny: self.model.deny(id)
                case .always: self.model.alwaysAllow(id)
                }
            }
        }
        autoDecideLoop = loop
        loop.start()
    }

    // MARK: Test-only compose

    /// `--test-compose TEXT`: once a session exists, opens the composer on it, polishes with the offline stub,
    /// optionally appends `NOTCH_AGENT_TEST_COMPOSE_EDIT` as the user's edit, and presses Send. Off unless the flag is passed.
    private func startTestComposeIfAsked() {
        guard let text = options.testCompose else { return }
        let env = ProcessInfo.processInfo.environment
        let edit = env["NOTCH_AGENT_TEST_COMPOSE_EDIT"] ?? ""
        let repeats = max(1, Int(env["NOTCH_AGENT_TEST_COMPOSE_REPEAT"] ?? "") ?? 1)
        Log.info("TEST MODE: composing one prompt for the first session (stub polish, \(repeats)x)")
        var started = false
        let loop = ObservationLoop<String?>({ [weak self] in self?.model.store.sessions.first?.id }) { [weak self] id in
            guard let id, !started else { return }
            started = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let composer = self.model.composer
                for round in 1...repeats {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.model.openComposer(sessionID: id)
                    composer.rawText = text
                    await composer.polish()
                    if composer.phase == .polished, !edit.isEmpty { composer.polishedText += "\n" + edit }
                    let polished = composer.phase == .polished
                    await composer.send()
                    Log.info("TEST MODE: compose round \(round): polished=\(polished) sent=\(composer.phase == .sent) style_changes=\(composer.chips.count)")
                    composer.close()
                }
            }
        }
        testComposeLoop = loop
        loop.start()
    }

    // MARK: Hotkeys

    private func handleHotkey(_ key: IslandHotkey) {
        Log.debug("hotkey: \(key == .defaultAction ? "⌥↵ (default)" : "⌥⌫ (deny)")")
        switch key {
        case .defaultAction: model.hotkeyDefault()
        case .deny: model.hotkeyDeny()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarImage()
        item.button?.toolTip = "notchAgent"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let install = NSMenuItem(title: "Install Claude Code hooks…", action: #selector(installHooks), keyEquivalent: "")
        install.target = self
        menu.addItem(install)
        demoItem.action = #selector(toggleDemo)
        demoItem.target = self
        menu.addItem(demoItem)
        menu.addItem(.separator())

        let compose = NSMenuItem(title: "Write a prompt…", action: #selector(openComposer), keyEquivalent: "p")
        compose.keyEquivalentModifierMask = [.control, .option]
        compose.target = self
        menu.addItem(compose)
        polishItem.action = #selector(togglePolish)
        polishItem.target = self
        polishItem.toolTip = "On: Polish sends the prompt text, your style notes and repo names to Anthropic. Off: prompts are sent as written and nothing leaves this Mac."
        menu.addItem(polishItem)
        let key = NSMenuItem(title: "Set Anthropic API key…", action: #selector(setAPIKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)
        let reveal = NSMenuItem(title: "Reveal learned style in Finder", action: #selector(revealStyle), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let reset = NSMenuItem(title: "Reset learned style…", action: #selector(resetStyle), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let revealApprovals = NSMenuItem(title: "Reveal learned approvals in Finder", action: #selector(revealApprovals), keyEquivalent: "")
        revealApprovals.target = self
        menu.addItem(revealApprovals)
        let resetApprovals = NSMenuItem(title: "Reset learned approvals…", action: #selector(resetApprovals), keyEquivalent: "")
        resetApprovals.target = self
        menu.addItem(resetApprovals)
        menu.addItem(.separator())
        serverItem.isEnabled = false
        autoItem.isEnabled = false
        learnedItem.isEnabled = false
        menu.addItem(serverItem)
        menu.addItem(autoItem)
        menu.addItem(learnedItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit notchAgent", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        switch serverState {
        case .starting: serverItem.title = "Hook server: starting…"
        case .on(let port): serverItem.title = "Hook server: 127.0.0.1:\(port)"
        case .off: serverItem.title = "Hook server: off"
        }
        autoItem.title = "Auto-allowed: \(liveStore.autoAllowedCount)"
        let decisions = approvals.model.decisions
        learnedItem.title = "Learned from \(decisions) decision\(decisions == 1 ? "" : "s")"
        demoItem.title = demoTask == nil ? "Play demo" : "Stop demo"
        polishItem.state = composerWiring.polishEnabled ? .on : .off
    }

    // MARK: Composer menu

    @objc private func openComposer() { model.openComposer() }

    @objc private func togglePolish() {
        composerWiring.polishEnabled.toggle()
        Log.info("polish: \(composerWiring.polishEnabled ? "on" : "off (prompts are sent as written)")")
        refreshMenu()
    }

    @objc private func setAPIKey() { composerWiring.promptForAPIKey() }

    @objc private func revealStyle() { composerWiring.revealStyle() }

    @objc private func resetStyle() { composerWiring.confirmAndResetStyle() }

    // MARK: Learned approvals menu

    @objc private func revealApprovals() {
        if FileManager.default.fileExists(atPath: approvalsURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([approvalsURL])
        } else {
            HookInstaller.alert(title: "Nothing learned yet", text: "The approval model is created the first time you allow or deny a request in the notch:\n\(approvalsURL.path)")
        }
    }

    @objc private func resetApprovals() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset the learned approvals?"
        alert.informativeText = "This forgets every Allow and Deny the model has learned from, in\n\(approvalsURL.path)"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        approvals.reset()
        Log.info("approvals: model reset")
        refreshMenu()
    }

    @objc private func installHooks() { HookInstaller.confirmAndInstall() }

    @objc private func toggleDemo() {
        if demoTask != nil { stopDemo() } else { playDemo() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Demo

    func playDemo() {
        stopDemo()
        let clock = DemoClock()
        let player: DemoPlayer
        if options.demoHTTP, case .on(let port) = serverState {
            // POST the payloads to our own server, like the hook script would.
            // The story's scripted Allow / Deny must not train the user's approval model.
            liveStore.learnsFromDecisions = false
            player = DemoPlayer(store: liveStore, clock: clock, mode: .live, transport: .http(port: port), model: model)
            Log.info("demo: playing the story over HTTP on port \(port)")
        } else {
            if options.demoHTTP { Log.info("demo: --demo-http needs the hook server; driving the store directly") }
            let store = DemoPlayer.makeStore(clock: clock)
            model.store = store
            player = DemoPlayer(store: store, clock: clock, mode: .live, model: model)
            Log.info("demo: playing the story through a demo store")
        }
        demoTask = Task { @MainActor [weak self] in
            await player.run()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.endDemo()
        }
        refreshMenu()
    }

    private func stopDemo() {
        guard let task = demoTask else { return }
        task.cancel()
        endDemo()
    }

    private func endDemo() {
        demoTask = nil
        model.forceProgress = false
        liveStore.learnsFromDecisions = true
        if model.store !== liveStore {
            model.store = liveStore
            Log.debug("demo: back to the live store")
        }
        refreshMenu()
    }

    /// The mascot as a template image for the menu bar.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 13)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            for r in ClawdShape.rects {
                NSBezierPath(rect: NSRect(x: r.minX * rect.width / 18, y: r.minY * rect.height / 13,
                                          width: r.width * rect.width / 18, height: r.height * rect.height / 13)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
