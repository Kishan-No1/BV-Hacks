// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import NotchAgentCore
import Observation
import SwiftUI

/// The island's view model: which store it renders, hover, toasts, and the displayed (animated) state.
@MainActor
@Observable
final class IslandModel {
    /// The store being rendered. Demo mode swaps in its own store and swaps the live one back after.
    var store: SessionStore {
        didSet {
            guard store !== oldValue else { return }
            toastClock.markSeen(store.toast)
            pinnedProgressSessionID = nil
        }
    }

    /// The prompt composer (rough text -> polish -> edit -> send). Inert until the app wires real services in.
    let composer = ComposerModel()

    var notch: NotchMetrics = .simulated
    /// The state on screen. Changes are applied with the open / nudge / close springs.
    private(set) var displayedState: IslandState = .idle
    private(set) var toastClock = ToastClock()
    /// Pointer inside the island's shape (raw, from the panel's mouse tracking).
    private(set) var pointerInside = false
    /// Debounced hover: true 120 ms after the pointer enters, false 220 ms after it leaves.
    private(set) var isHovering = false
    /// Demo mode opens Progress during the story's 'progress' beat.
    var forceProgress = false
    /// The session Progress shows while it is open and nothing is selected, so it does not flip between sessions.
    private(set) var pinnedProgressSessionID: String?
    /// Measured request-card heights, keyed by request id.
    private(set) var requestHeights: [UUID: CGFloat] = [:]

    /// A hotkey only acts on a request that has been on screen this long, and not sooner than this after
    /// the previous decision: a double tap, or a key already on its way down when a card appears, must
    /// never answer a request the user has not read.
    static let hotkeyGuardInterval: TimeInterval = 0.5
    /// The request card on screen and when the island first rendered it.
    @ObservationIgnored private var shownRequest: (id: UUID, since: Date)?
    @ObservationIgnored private var lastDecisionAt: Date?
    /// The clock for the hotkey guard (tests replace it).
    @ObservationIgnored var now: () -> Date = { Date() }

    @ObservationIgnored private var isPrerolling = false
    @ObservationIgnored var onStateChange: ((IslandState) -> Void)?
    @ObservationIgnored private var stateLoop: ObservationLoop<IslandState>?
    @ObservationIgnored private var toastLoop: ObservationLoop<UUID?>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored let renderMode: RenderMode

    init(store: SessionStore, renderMode: RenderMode = .live) {
        self.store = store
        self.renderMode = renderMode
        composer.session = { [weak self] id in self?.store.session(id: id) }
        composer.isSessionBlocked = { [weak self] id in
            guard let self else { return false }
            return self.store.pending.contains { $0.sessionID == id } || self.store.session(id: id)?.status == .needsYou
        }
    }

    // MARK: Derivation

    /// "Needs your input" cards the user closed with Dismiss (they fall back to the attention dot).
    private(set) var dismissedInputs: Set<String> = []

    var derivedState: IslandState {
        IslandState.derive(store: store, visibleToast: toastClock.visible?.kind, isHovering: isHovering,
                           forceProgress: forceProgress, composer: composer.isOpen ? composer.layout : nil,
                           dismissedInputs: dismissedInputs)
    }

    func dismissInput(sessionID: String, _ attention: Attention) {
        Log.debug("action: dismiss input card")
        dismissedInputs.insert(IslandState.inputKey(sessionID: sessionID, attention))
        if dismissedInputs.count > 64 { dismissedInputs.removeFirst() }
    }

    /// Brings the app running the session (Terminal, iTerm, the Claude app…) to the front.
    func openSession(_ sessionID: String) {
        guard let pid = store.session(id: sessionID)?.process?.pid else {
            Log.info("open session: no known process for \(sessionID)")
            return
        }
        for ancestor in ProcessLiveness.ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                Log.debug("action: open session -> \(app.localizedName ?? "app")")
                app.activate()
                return
            }
        }
        Log.info("open session: no app found above pid \(pid)")
    }

    /// The session Progress shows: the clicked avatar, else the one pinned when Progress opened, else the store's pick.
    var progressSession: Session? {
        if let id = store.selectedSessionID, let s = store.session(id: id) { return s }
        if let id = pinnedProgressSessionID, let s = store.session(id: id) { return s }
        return store.activeSession
    }

    func size(for state: IslandState) -> CGSize {
        if case .request(let r) = state {
            return IslandGeometry.size(for: state, notch: notch, requestHeight: requestHeights[r.id])
        }
        return IslandGeometry.size(for: state, notch: notch)
    }

    var displayedSize: CGSize { size(for: displayedState) }

    // MARK: Lifecycle

    func start() {
        toastLoop = ObservationLoop({ [weak self] in self?.store.toast?.id }) { [weak self] _ in
            self?.observeToast()
        }
        toastLoop?.start()
        stateLoop = ObservationLoop({ [weak self] in self?.derivedState ?? .idle }) { [weak self] state in
            guard let self, !self.isPrerolling else { return }
            self.apply(state)
        }
        stateLoop?.start()
    }

    func stop() {
        toastLoop?.cancel()
        stateLoop?.cancel()
        hoverTask?.cancel()
        toastTask?.cancel()
    }

    /// Shows `state` with the prototype's springs (or instantly in snapshot mode).
    func apply(_ state: IslandState, animated: Bool = true) {
        prepare(state)
        guard state != displayedState else { return }
        if case .request(let r) = state {
            if shownRequest?.id != r.id { shownRequest = (r.id, now()) }
        } else {
            shownRequest = nil
        }
        let old = displayedState
        if state == .progress, old != .progress {
            pinnedProgressSessionID = store.selectedSessionID == nil ? store.activeSession?.id : nil
        } else if state != .progress {
            pinnedProgressSessionID = nil
        }
        let motion = IslandMotion.kind(from: old, to: state, fromSize: size(for: old), toSize: size(for: state))
        if animated && renderMode.animated {
            withAnimation(motion.animation) { displayedState = state }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { displayedState = state }
        }
        Log.debug("island: \(old.logName) -> \(state.logName)")
        onStateChange?(state)
        pruneHeights()
    }

    /// Measures a request card before it is shown, like the prototype's `measure()`.
    func prepare(_ state: IslandState) {
        guard case .request(let r) = state, requestHeights[r.id] == nil else { return }
        requestHeights[r.id] = RequestMeasurer.height(for: r, model: self)
    }

    private func pruneHeights() {
        let live = Set(store.pending.map(\.id))
        if requestHeights.count > 16 { requestHeights = requestHeights.filter { live.contains($0.key) } }
    }

    // MARK: Toasts

    private func observeToast() {
        if isPrerolling {
            toastClock.markSeen(store.toast)
            return
        }
        let now = Date()
        guard toastClock.observe(store.toast, now: now) else { return }
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ToastClock.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toastClock.expire(now: Date())
        }
    }

    /// While the demo fast-forwards its history, the island keeps showing what it showed before
    /// (no flash of "working" or a stale "Done" toast), then catches up in one step.
    func beginPreroll() {
        isPrerolling = true
    }

    func endPreroll() {
        isPrerolling = false
        toastClock.markSeen(store.toast)
        apply(derivedState)
    }

    // MARK: Hover

    /// `inside`: the pointer is over the island as drawn. `nearNotch`: it is over the island's collapsed
    /// (notch-sized) shape. Hover only opens from the notch, so a card that pops open under the pointer
    /// never turns into a Progress view that keeps itself open; once open it stays while the pointer is inside.
    func setPointerInside(_ inside: Bool, nearNotch: Bool = true) {
        let wanted = isHovering ? inside : (inside && nearNotch)
        guard wanted != pointerInside else { return }
        pointerInside = wanted
        hoverTask?.cancel()
        guard wanted != isHovering else { return }
        let delay = wanted ? HoverTiming.openDelay : HoverTiming.closeDelay
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pointerInside == wanted else { return }
            self.isHovering = wanted
        }
    }

    /// Closes a hover-opened Progress at once; the pointer has to come back to the notch to reopen it.
    func resetHover() {
        hoverTask?.cancel()
        pointerInside = false
        isHovering = false
    }

    /// Another app came to the front. The island goes back to its resting state, and when that app is the
    /// one running a session (the Claude app, a terminal), the user is now handling that session there:
    /// its "needs your input" card and its request cards are put away (Claude Code shows its own prompt).
    func appActivated(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        resetHover()
        for s in store.sessions {
            guard let process = s.process, Self.hostApp(of: process.pid) == pid else { continue }
            if let a = s.attention {
                dismissedInputs.insert(IslandState.inputKey(sessionID: s.id, a))
            }
            for r in store.pending where r.sessionID == s.id {
                Log.debug("app activated: handing \(r.toolName) back to the session's app")
                store.dismiss(r.id)
            }
        }
        if dismissedInputs.count > 64 { dismissedInputs.removeFirst() }
    }

    /// The regular (Dock) app above `pid`: the app the session runs in.
    static func hostApp(of pid: Int32) -> pid_t? {
        for ancestor in ProcessLiveness.ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                return app.processIdentifier
            }
        }
        return nil
    }

    // MARK: Actions (buttons, hotkeys)

    /// The request a hotkey may answer right now: the current one, only if it is the card on screen, has
    /// been there for `hotkeyGuardInterval`, and no decision was made within that interval. nil otherwise.
    func hotkeyTarget() -> PendingRequest? {
        guard let r = store.currentRequest else { return nil }
        guard case .request(let displayed) = displayedState, displayed.id == r.id,
              let shown = shownRequest, shown.id == r.id else {
            Log.debug("hotkey ignored: the request is not on screen yet")
            return nil
        }
        let t = now()
        guard t.timeIntervalSince(shown.since) >= Self.hotkeyGuardInterval else {
            Log.debug("hotkey ignored: the request has been on screen for less than \(Self.hotkeyGuardInterval)s")
            return nil
        }
        if let last = lastDecisionAt, t.timeIntervalSince(last) < Self.hotkeyGuardInterval {
            Log.debug("hotkey ignored: a decision was made less than \(Self.hotkeyGuardInterval)s ago")
            return nil
        }
        return r
    }

    /// ⌥↵: the default decision (allow for low/review, deny for high) for the request on screen.
    func hotkeyDefault() {
        guard let r = hotkeyTarget() else { return }
        Log.debug("action: default (\(r.defaultDecision.isAllow ? "allow" : "deny")) for \(r.toolName)")
        resolve(r.id, r.defaultDecision)
    }

    /// ⌥⌫: deny the request on screen.
    func hotkeyDeny() {
        guard let r = hotkeyTarget() else { return }
        deny(r.id)
    }

    /// The default decision without the hotkey guard (`--test-autodecide`, which waits by itself).
    func performDefault() {
        guard let r = store.currentRequest else { return }
        Log.debug("action: default (\(r.defaultDecision.isAllow ? "allow" : "deny")) for \(r.toolName)")
        resolve(r.id, r.defaultDecision)
    }

    private func resolve(_ id: UUID, _ decision: Decision, remember: Bool = false) {
        lastDecisionAt = now()
        store.resolve(id, decision, remember: remember)
    }

    func allow(_ id: UUID) {
        Log.debug("action: allow")
        resolve(id, .allow)
    }

    func alwaysAllow(_ id: UUID) {
        Log.debug("action: always allow")
        resolve(id, .allow, remember: true)
    }

    func deny(_ id: UUID) {
        Log.debug("action: deny")
        resolve(id, .deny(message: nil))
    }

    func openDiff(_ request: PendingRequest) {
        guard let path = request.assessment.diff?.filePath, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            Log.info("open diff: \(path) does not exist")
        }
    }

    func select(sessionID: String) {
        store.selectedSessionID = sessionID
    }

    // MARK: Composer

    /// Opens the composer aimed at `sessionID`, else the session Progress shows, else the first one.
    func openComposer(sessionID: String? = nil) {
        let target = sessionID ?? store.selectedSessionID ?? progressSession?.id ?? store.sessions.first?.id
        Log.debug("action: open composer")
        composer.open(sessionID: target)
    }

    /// ⌃⌥P: open the composer, or close it and keep the draft.
    func toggleComposer() {
        if composer.isOpen { composer.close() } else { openComposer() }
    }

    /// An avatar click in Progress: the avatar already showing opens the composer for that session; any
    /// other avatar switches Progress to it, as before.
    func avatarClicked(_ sessionID: String) {
        if progressSession?.id == sessionID {
            openComposer(sessionID: sessionID)
        } else {
            select(sessionID: sessionID)
        }
    }
}

/// How the island renders: live (animated, native glass, real clock) or a frozen snapshot.
struct RenderMode: Equatable {
    /// Fixed "now" for live counters; nil = the real clock.
    var frozenNow: Date?
    /// Use SwiftUI's native Liquid Glass (`.glassEffect`). Off in snapshots (it does not render offscreen).
    var nativeGlass: Bool
    /// Run looping animations (wave, pulse, step rise).
    var animated: Bool

    static var live: RenderMode {
        let glassOff = ProcessInfo.processInfo.environment["NOTCH_AGENT_GLASS"] == "0"
        return RenderMode(frozenNow: nil, nativeGlass: !glassOff, animated: true)
    }

    static func snapshot(now: Date) -> RenderMode {
        RenderMode(frozenNow: now, nativeGlass: false, animated: false)
    }
}

// A plain key instead of `@Entry`: the macro needs Xcode's SwiftUI macro plugin, so the app would not
// build with the Command Line Tools alone.
private struct NotchAgentRenderKey: EnvironmentKey {
    static var defaultValue: RenderMode { .live }
}

extension EnvironmentValues {
    var notchAgentRender: RenderMode {
        get { self[NotchAgentRenderKey.self] }
        set { self[NotchAgentRenderKey.self] = newValue }
    }
}
