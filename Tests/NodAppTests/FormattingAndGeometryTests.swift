// OWNER: workstream C (app-ui).
import CoreGraphics
import Foundation
import Testing
@testable import Nod
import NodCore

@Suite("Formatting")
struct FormattingTests {
    @Test func durations() {
        #expect(Format.duration(0) == "0s")
        #expect(Format.duration(42.7) == "42s")
        #expect(Format.duration(552) == "9m 12s")
        #expect(Format.duration(600) == "10m 0s")
        #expect(Format.duration(3780) == "1h 3m")
    }

    @Test func liveSeconds() {
        #expect(Format.seconds(12.5) == "12.50 seconds")
        #expect(Format.seconds(-3) == "0.00 seconds")
    }

    @Test func filesChanged() {
        #expect(Format.filesChanged(0) == "No files changed")
        #expect(Format.filesChanged(1) == "1 file changed")
        #expect(Format.filesChanged(3) == "3 files changed")
    }

    @Test func finishedSummaryUsesTheTurnDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var s = Session(id: "a", cwd: "/tmp/a", name: "a", status: .done, lastEventAt: start)
        s.turnStartedAt = start
        s.turnEndedAt = start.addingTimeInterval(552)
        s.editedFiles = ["/a", "/b", "/c"]
        #expect(Format.finishedSummary(s) == "3 files changed · 9m 12s")
        s.turnStartedAt = nil
        #expect(Format.finishedSummary(s) == "3 files changed")
    }

    @Test func toolBarMatchesThePrototype() {
        // prototype: Math.min(92, 18 + t * 2.4) percent
        #expect(abs(Format.toolBarFraction(elapsed: 0) - 0.18) < 1e-9)
        #expect(abs(Format.toolBarFraction(elapsed: 12.5) - 0.48) < 1e-9)
        #expect(Format.toolBarFraction(elapsed: 500) == 0.92)
    }

    @Test func backtickSpansBecomeCode() {
        #expect(InlineCode.segments("Read `src/auth/session.ts`") == [
            .init(text: "Read ", isCode: false), .init(text: "src/auth/session.ts", isCode: true),
        ])
        #expect(InlineCode.segments("Ran `npm test` twice") == [
            .init(text: "Ran ", isCode: false), .init(text: "npm test", isCode: true), .init(text: " twice", isCode: false),
        ])
        #expect(InlineCode.segments("plain") == [.init(text: "plain", isCode: false)])
        #expect(InlineCode.segments("") == [])
    }

    @Test func anUnmatchedBacktickStaysPlain() {
        #expect(InlineCode.segments("Run `npm test") == [.init(text: "Run `npm test", isCode: false)])
        #expect(InlineCode.segments("a `b` c `d") == [
            .init(text: "a ", isCode: false), .init(text: "b", isCode: true), .init(text: " c `d", isCode: false),
        ])
    }

    @Test func plainTextDropsBackticks() {
        #expect(InlineCode.plain("Edit `session.ts` now") == "Edit session.ts now")
    }

    @Test func requestDetailFallsBackToTheToolInput() {
        #expect(Format.requestDetail(toolName: "WebFetch", input: ["url": "https://docs.example.com/a", "prompt": "x"]) == "https://docs.example.com/a")
        #expect(Format.requestDetail(toolName: "WebSearch", input: ["query": "swift glass"]) == "swift glass")
        #expect(Format.requestDetail(toolName: "Read", input: ["file_path": "/a/b.ts"]) == "/a/b.ts")
        #expect(Format.requestDetail(toolName: "mcp__x__y", input: [:]) == "mcp__x__y")
    }

    @Test func commandFirstLine() {
        #expect(Format.commandLine("npm test") == "npm test")
        #expect(Format.commandLine("echo a\necho b") == "echo a …")
    }
}

@Suite("Notch geometry")
struct GeometryTests {
    @Test func hardwareNotchFromScreenMetrics() {
        // 14" MacBook Pro at default scaling: 1512 x 982 points.
        let n = NotchMetrics.from(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  safeAreaTop: 32, auxLeftWidth: 663.5, auxRightWidth: 663.5)
        #expect(n.hasHardwareNotch)
        #expect(n.width == 185)
        #expect(n.height == 32)
        #expect(n.centerX == 756)
    }

    @Test func noNotchSimulatesOne() {
        let n = NotchMetrics.from(screenFrame: CGRect(x: 100, y: 0, width: 1920, height: 1080),
                                  safeAreaTop: 0, auxLeftWidth: nil, auxRightWidth: nil)
        #expect(!n.hasHardwareNotch)
        #expect(n.width == 185)
        #expect(n.height == 32)
        #expect(n.centerX == 1060)
    }

    @Test func compactSizesMatchThePrototype() {
        let n = NotchMetrics.simulated
        #expect(IslandGeometry.size(for: .idle, notch: n) == CGSize(width: 185, height: 32))
        #expect(IslandGeometry.size(for: .working, notch: n) == CGSize(width: 272, height: 32))
        #expect(IslandGeometry.size(for: .attention, notch: n) == CGSize(width: 272, height: 32))
        #expect(IslandGeometry.size(for: .progress, notch: n) == CGSize(width: 600, height: 256))
        #expect(IslandGeometry.size(for: .toast(.done), notch: n) == CGSize(width: 310, height: 32))
        #expect(IslandGeometry.size(for: .toast(.allowed), notch: n) == CGSize(width: 290, height: 32))
        #expect(IslandGeometry.size(for: .toast(.denied), notch: n) == CGSize(width: 290, height: 32))
        #expect(IslandGeometry.cornerRadius(for: .progress) == 34)
        #expect(IslandGeometry.cornerRadius(for: .working) == 10)
    }

    @Test func compactStatesFollowAWiderNotch() {
        let n = NotchMetrics(width: 200, height: 38, centerX: 0, hasHardwareNotch: true)
        #expect(IslandGeometry.size(for: .idle, notch: n) == CGSize(width: 200, height: 38))
        #expect(IslandGeometry.size(for: .working, notch: n) == CGSize(width: 287, height: 38))
    }

    @Test func requestUsesMeasuredHeight() {
        let r = PendingRequest(sessionID: "a", toolName: "Bash", toolInput: [:], cwd: "/",
                               assessment: Assessment(level: .low, title: "x"), receivedAt: Date())
        #expect(IslandGeometry.size(for: .request(r), notch: .simulated, requestHeight: 231) == CGSize(width: 560, height: 231))
        #expect(IslandGeometry.size(for: .request(r), notch: .simulated).width == 560)
    }

    @Test func panelIsPinnedTopCenterAndHitRectCoversTheIslandAndShoulders() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let panel = IslandGeometry.panelFrame(screenFrame: screen, centerX: 756)
        #expect(panel == CGRect(x: 756 - 380, y: 982 - 420, width: 760, height: 420))
        let hit = IslandGeometry.hitRect(islandSize: CGSize(width: 272, height: 32), panelFrame: panel)
        #expect(hit == CGRect(x: 756 - 136 - 10, y: 982 - 32, width: 292, height: 32))
        #expect(hit.contains(CGPoint(x: 756, y: 970)))
        #expect(!hit.contains(CGPoint(x: 756, y: 900)))
    }

    @Test func springChoiceFollowsThePrototype() {
        #expect(IslandMotion.kind(from: .working, to: .progress, fromSize: CGSize(width: 272, height: 32), toSize: CGSize(width: 600, height: 256)) == .open)
        #expect(IslandMotion.kind(from: .idle, to: .working, fromSize: CGSize(width: 185, height: 32), toSize: CGSize(width: 272, height: 32)) == .nudge)
        #expect(IslandMotion.kind(from: .progress, to: .working, fromSize: CGSize(width: 600, height: 256), toSize: CGSize(width: 272, height: 32)) == .close)
    }
}
