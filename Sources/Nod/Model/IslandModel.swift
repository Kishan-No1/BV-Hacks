// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import NodCore
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
    }

    // MARK: Derivation

    var derivedState: IslandState {
        IslandState.derive(store: store, visibleToast: toastClock.visible?.kind, isHovering: isHovering, forceProgress: forceProgress)
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

    func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        guard inside != isHovering else { return }
        let delay = inside ? HoverTiming.openDelay : HoverTiming.closeDelay
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pointerInside == inside else { return }
            self.isHovering = inside
        }
    }

    // MARK: Actions (buttons, hotkeys)

    /// ⌥↵ and the primary button: allow for low/review, deny for high.
    func performDefault() {
        guard let r = store.currentRequest else { return }
        Log.debug("action: default (\(r.defaultDecision.isAllow ? "allow" : "deny")) for \(r.toolName)")
        store.resolve(r.id, r.defaultDecision)
    }

    func allow(_ id: UUID) {
        Log.debug("action: allow")
        store.resolve(id, .allow)
    }

    func alwaysAllow(_ id: UUID) {
        Log.debug("action: always allow")
        store.resolve(id, .allow, remember: true)
    }

    func deny(_ id: UUID) {
        Log.debug("action: deny")
        store.resolve(id, .deny(message: nil))
    }

    func denyCurrent() {
        guard let r = store.currentRequest else { return }
        deny(r.id)
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
        let glassOff = ProcessInfo.processInfo.environment["NOD_GLASS"] == "0"
        return RenderMode(frozenNow: nil, nativeGlass: !glassOff, animated: true)
    }

    static func snapshot(now: Date) -> RenderMode {
        RenderMode(frozenNow: now, nativeGlass: false, animated: false)
    }
}

extension EnvironmentValues {
    @Entry var nodRender: RenderMode = .live
}
