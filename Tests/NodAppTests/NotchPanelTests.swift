import AppKit
import Testing
@testable import Nod

@MainActor
@Suite("Notch panel window")
struct NotchPanelTests {
    /// The island must draw over the menu bar. A level at or below `.mainMenu` puts the menu bar on top of the
    /// island's upper part, so the island looks like it hangs below the notch instead of growing out of it.
    @Test func panelSitsAboveTheMenuBar() {
        let panel = NotchPanel()
        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.level == NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
    }

    /// The window server must not push the frame below the menu bar either.
    @Test func frameIsNotConstrainedBelowTheMenuBar() {
        let panel = NotchPanel()
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let top = NSRect(x: 376, y: 562, width: 760, height: 420)
        #expect(panel.constrainFrameRect(top, to: nil) == top)
        #expect(top.maxY == screen.maxY)
    }
}
