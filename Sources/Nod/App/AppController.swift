// OWNER: workstream C (app-ui).
import AppKit
import NodCore
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
    let liveStore: SessionStore
    let server: HookServer
    let model: IslandModel
    private(set) var serverState: ServerState = .starting

    private var panel: NotchPanelController?
    private var hotkeys: HotkeyController?
    private var registrar: CarbonHotkeyRegistrar?
    private var statusItem: NSStatusItem?
    private var demoTask: Task<Void, Never>?
    private var autoDecideLoop: ObservationLoop<UUID?>?
    private var activity: NSObjectProtocol?
    private let serverItem = NSMenuItem(title: "Hook server: starting…", action: nil, keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Auto-allowed: 0", action: nil, keyEquivalent: "")
    private let demoItem = NSMenuItem(title: "Play demo", action: nil, keyEquivalent: "")

    init(options: LaunchOptions) {
        self.options = options
        rules = RulesStore(fileURL: options.rulesFile.map { URL(fileURLWithPath: $0) } ?? RulesStore.defaultFileURL)
        liveStore = SessionStore(rules: rules)
        server = HookServer(port: options.port, handler: liveStore.hookHandler())
        model = IslandModel(store: liveStore)
        super.init()
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

        startAutoDecideIfAsked()
        startServer()
        Log.info("Nod \(NodMain.version) running (hook port \(options.port))\(options.demo ? ", demo mode" : "")")

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
        server.stop()
        panel?.close()
    }

    // MARK: Server

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
        let delay = max(0, Double(env["NOD_TEST_DECIDE_DELAY"] ?? "") ?? 0.4)
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
        item.button?.toolTip = "Nod"
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
        serverItem.isEnabled = false
        autoItem.isEnabled = false
        menu.addItem(serverItem)
        menu.addItem(autoItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nod", action: #selector(quit), keyEquivalent: "q")
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
        demoItem.title = demoTask == nil ? "Play demo" : "Stop demo"
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
