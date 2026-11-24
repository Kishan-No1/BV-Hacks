// OWNER: workstream C (app-ui).
import AppKit
import SwiftUI

/// Borderless, non-activating panel above the menu bar, on every space and over full-screen apps.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: IslandGeometry.canvas),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        // Must come after `isFloatingPanel`: setting that resets the level to `.floating` (3), which is below the
        // menu bar (24), so the menu bar would cover the top of the island.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    /// True only while the prompt composer is open. The rest of the time the panel never takes the keyboard
    /// from the user's app. Even then the app itself is not activated (the panel is non-activating).
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    // Allow the frame to sit over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks land on the first try even though the panel never becomes key.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pins the panel to the notch, keeps it there across display changes, and makes it click-through everywhere
/// except the island's current shape (toggling `ignoresMouseEvents` from mouse monitors).
@MainActor
final class NotchPanelController {
    let panel = NotchPanel()
    let model: IslandModel
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var stateLoop: ObservationLoop<CGSize>?
    private var keyLoop: ObservationLoop<Bool>?
    private var trackingOwner: TrackingOwner?

    init(model: IslandModel) {
        self.model = model
        let root = IslandCanvas(model: model)
            .environment(\.notchAgentRender, model.renderMode)
            .environment(\.colorScheme, .dark)
        let host = IslandHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: IslandGeometry.canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        let owner = TrackingOwner { [weak self] in self?.updatePointer() }
        trackingOwner = owner
        host.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: owner, userInfo: nil))
    }

    func show() {
        pin()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pin() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited]) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer() }
            return event
        }
        // Safety net for missed events (space switches, sleep).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        stateLoop = ObservationLoop({ [weak self] in self?.model.displayedSize ?? .zero }) { [weak self] _ in
            self?.updatePointer()
        }
        stateLoop?.start()
        keyLoop = ObservationLoop({ [weak self] in self?.model.composer.isOpen ?? false }) { [weak self] open in
            self?.setKeyboard(open)
        }
        keyLoop?.start()
    }

    /// The composer needs the keyboard; everything else must leave it with the user's app.
    private func setKeyboard(_ wanted: Bool) {
        guard panel.allowsKey != wanted else { return }
        panel.allowsKey = wanted
        if wanted {
            panel.makeKey()
            Log.debug("panel: took the keyboard for the composer (key=\(panel.isKeyWindow))")
        } else {
            // A window that can no longer be key gives the keyboard back when it is re-ordered: the system
            // returns key status to the frontmost app's window. The panel itself stays in front.
            panel.makeFirstResponder(nil)
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            Log.debug("panel: gave the keyboard back (key=\(panel.isKeyWindow))")
        }
    }

    func close() {
        keyLoop?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        pollTimer?.invalidate()
        stateLoop?.cancel()
        panel.orderOut(nil)
    }

    /// The screen with a notch, else the main screen (with a simulated 185 x 32 notch).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func pin() {
        guard let screen = Self.targetScreen() else { return }
        let notch = NotchMetrics.from(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                      auxLeftWidth: screen.auxiliaryTopLeftArea?.width, auxRightWidth: screen.auxiliaryTopRightArea?.width)
        if model.notch != notch { model.notch = notch }
        let frame = IslandGeometry.panelFrame(screenFrame: screen.frame, centerX: notch.centerX)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        Log.debug("panel: pinned to \(screen.localizedName) frame=\(NSStringFromRect(frame)) notch=\(Int(notch.width))x\(Int(notch.height))\(notch.hasHardwareNotch ? "" : " (simulated)")")
        updatePointer()
    }

    /// The island's clickable rect in screen coordinates, or nil when there is nothing to interact with.
    var hitRect: CGRect? {
        if model.displayedState == .idle && model.store.sessions.isEmpty && !model.nowPlaying.isActive { return nil }
        return IslandGeometry.hitRect(islandSize: model.displayedSize, panelFrame: panel.frame)
    }

    func updatePointer() {
        let p = NSEvent.mouseLocation
        let inside = hitRect?.contains(p) ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let nearNotch = inside && IslandGeometry.hitRect(islandSize: model.size(for: .working), panelFrame: panel.frame).contains(p)
        model.setPointerInside(inside, nearNotch: nearNotch)
        model.setPointer(inside ? CGPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y) : nil)
    }
}

/// Receives tracking-area callbacks while the pointer is over the panel.
private final class TrackingOwner: NSResponder {
    let onMove: () -> Void
    init(onMove: @escaping () -> Void) {
        self.onMove = onMove
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }
}
