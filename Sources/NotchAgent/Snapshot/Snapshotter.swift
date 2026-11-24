// OWNER: workstream C (app-ui).
import AppKit
import NotchAgentCore
import SwiftUI

/// `notchAgent --snapshot DIR`: renders every island state to PNG at 2x, offscreen, then exits.
/// The store is filled by the demo payloads (fast-forwarded), so the content is what the real path produces.
/// Native Liquid Glass does not render offscreen; snapshots use the gradient fallback (`RenderMode.nativeGlass == false`).
@MainActor
enum Snapshotter {
    static let names = ["idle", "working", "attention", "progress", "progress-done", "request-low", "request-review",
                        "request-high", "request-unusual", "toast-done", "toast-allowed", "toast-denied",
                        "composer-draft", "composer-polished", "composer-error", "composer-sent", "input-question",
                        "now-playing", "media", "progress-media"]

    static func run(directory: String) async -> Bool {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.info("snapshot: cannot create \(dir.path): \(error)")
            return false
        }

        let clock = DemoClock(virtualBase: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = DemoPlayer.makeStore(clock: clock)
        let model = IslandModel(store: store, renderMode: .snapshot(now: clock.now()))
        let player = DemoPlayer(store: store, clock: clock, mode: .fastForward, model: model)
        var written: [String] = []
        var failed: [String] = []

        func shoot(_ name: String, _ expected: IslandState? = nil) {
            // Toasts and progress-done are shown explicitly; everything else is what the store derives.
            let state = expected ?? IslandState.derive(store: store, visibleToast: nil, isHovering: false,
                                                       forceProgress: model.forceProgress)
            model.apply(state, animated: false)
            if render(model: model, now: clock.now(), to: dir.appendingPathComponent("\(name).png")) {
                written.append(name)
            } else {
                failed.append(name)
            }
        }

        await player.run { index, beat in
            switch (index, beat.name) {
            case (0, "idle"): shoot("idle")
            case (1, "working"): shoot("working")
            case (2, "progress"): shoot("progress")
            case (4, "attention"): shoot("attention")
            case (5, "low"): shoot("request-low")
            case (6, "allowed"): shoot("toast-allowed", .toast(.allowed))
            case (7, "med"): shoot("request-review")
            case (10, "high"): shoot("request-high")
            case (11, "denied"): shoot("toast-denied", .toast(.denied))
            case (13, "done"): shoot("toast-done", .toast(.done))
            default: break
            }
        }
        // Progress for the finished CI session: the green Finished card.
        store.selectedSessionID = DemoScript.ci.id
        shoot("progress-done", .progress)

        // The amber learned-approval chip: a request the risk engine does not rate high, which this user keeps denying.
        store.selectedSessionID = nil
        if let event = try? HookEvent.decode(DemoScript.permission(DemoScript.ci, "Bash", DemoScript.ciDeploy)) {
            let held = Task { @MainActor in await store.requestDecision(for: event, timeout: 300) }
            for _ in 0..<50 where store.pending.isEmpty { await Task.yield() }
            if let request = store.pending.first {
                if store.predictions[request.id]?.unusual != true { Log.info("snapshot: the deploy request has no 'Unusual' chip") }
                shoot("request-unusual")
                store.dismiss(request.id)
            } else {
                failed.append("request-unusual")
            }
            _ = await held.value
        }

        // The prompt composer, in fixed states (no polish call, no send).
        let composer = model.composer
        let rough = "fix the flaky login test, its the session refresh timing i think"
        let polished = "Fix the flaky login test in src/auth. The likely cause is session refresh timing, so start with "
            + "refreshSession in src/auth/session.ts and the expiry check. Keep the change small.\nRun tests after edits."
        composer.showForSnapshot(phase: .draft, sessionID: DemoScript.auth.id, raw: rough)
        shoot("composer-draft", .composer(composer.layout))
        composer.showForSnapshot(phase: .polished, sessionID: DemoScript.auth.id, raw: rough, polished: polished)
        shoot("composer-polished", .composer(composer.layout))
        composer.showForSnapshot(phase: .draft, sessionID: DemoScript.auth.id, raw: rough, error: PolishError.noKey.userMessage)
        shoot("composer-error", .composer(composer.layout))
        composer.showForSnapshot(phase: .sent, sessionID: DemoScript.auth.id, raw: "",
                                 chips: ["Learned: Add: “Run tests after edits”", "Learned: Don't say “please”."],
                                 sentLabel: "Sent to acme-web")
        shoot("composer-sent", .composer(composer.layout))
        composer.discard()

        // A question Claude asks in its own UI: the island pops the "needs your input" card.
        let question = #"{"session_id":"\#(DemoScript.auth.id)","hook_event_name":"PermissionRequest","cwd":"\#(DemoScript.auth.cwd)","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should the cache use?","options":[{"label":"Redis"},{"label":"SQLite"},{"label":"In-memory"}]}]}}"#
        if let event = try? HookEvent.decode(Data(question.utf8)) {
            _ = await store.requestDecision(for: event)
            shoot("input-question")
        } else {
            failed.append("input-question")
        }

        // Spotify: the collapsed wave, the player alone, and Progress split with the player.
        model.nowPlaying.showForSnapshot(.init(id: "snap", name: "High Hopes", artist: "David Gilmour",
                                               album: "Live at Pompeii", duration: 571),
                                         playing: true, position: 32, at: clock.now(), repeating: true)
        shoot("now-playing", .nowPlaying)
        shoot("media", .media)
        store.selectedSessionID = DemoScript.auth.id
        // The pointer between the two cards' top edges, so both border glows show.
        model.setPointer(CGPoint(x: 392, y: 46))
        shoot("progress-media", .progress)
        model.setPointer(nil)

        Log.info("snapshot: wrote \(written.count) PNGs to \(dir.path)\(failed.isEmpty ? "" : "; failed: \(failed.joined(separator: ", "))")")
        return failed.isEmpty && Set(written) == Set(names)
    }

    static func render(model: IslandModel, now: Date, to url: URL) -> Bool {
        let scene = SnapshotScene(model: model)
            .environment(\.notchAgentRender, RenderMode.snapshot(now: now))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else {
            Log.info("snapshot: ImageRenderer returned no image for \(url.lastPathComponent)")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width / 2, height: cg.height / 2)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            Log.info("snapshot: write failed: \(error)")
            return false
        }
    }
}

/// A desktop-like backdrop (the prototype's `.screen`: gradient wallpaper, menu bar, an editor window) with the
/// island canvas pinned at the top center.
struct SnapshotScene: View {
    let model: IslandModel

    static let size = IslandGeometry.canvas

    var body: some View {
        ZStack(alignment: .top) {
            DesktopBackdrop()
            IslandCanvas(model: model)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }
}

struct DesktopBackdrop: View {
    /// The prototype's screen is 1512 wide; the canvas shows its center.
    private let cropX: CGFloat = (1512 - IslandGeometry.canvas.width) / 2

    private static let code: [String] = [
        "// you stay in your editor. the agents work in the background.",
        "import { SessionError } from './errors';",
        "",
        "export async function refreshSession(token: string) {",
        "  const res = await fetch('/api/session', {",
        "    method: 'POST',",
        "    headers: { Authorization: `Bearer ${token}` },",
        "  });",
        "  if (!res.ok) throw new SessionError(res.status);",
        "  return res.json();",
        "}",
        "",
        "export function isExpired(exp: number) {",
        "  return Date.now() > exp * 1000 - 30_000;",
        "}",
    ]

    var body: some View {
        let w = IslandGeometry.canvas.width, h = IslandGeometry.canvas.height
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0x1A1E3A), location: 0), .init(color: Color(hex: 0x2B2357), location: 0.55),
                                   .init(color: Color(hex: 0x4A2A5E), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: 640)
            // radial-gradient(1400px 700px at 10% 120%, #ff7a45 0%, transparent 55%)
            EllipticalGradient(colors: [Color(hex: 0xFF7A45), Color(hex: 0xFF7A45, opacity: 0)], center: .center,
                               startRadiusFraction: 0, endRadiusFraction: 0.275)
                .frame(width: 2800, height: 1400)
                .position(x: 151 - cropX, y: 768)
            // radial-gradient(1200px 700px at 92% 125%, #7b3fe4 0%, transparent 60%)
            EllipticalGradient(colors: [Color(hex: 0x7B3FE4), Color(hex: 0x7B3FE4, opacity: 0)], center: .center,
                               startRadiusFraction: 0, endRadiusFraction: 0.3)
                .frame(width: 2400, height: 1400)
                .position(x: 1391 - cropX, y: 800)
            // .menubar
            Rectangle().fill(Color(red: 20 / 255, green: 20 / 255, blue: 35 / 255, opacity: 0.32))
                .frame(width: w, height: 37)
            // .win: left 330, right 40, top 52 on the 1512-wide screen.
            editor
                .frame(width: 1512 - 330 - 40, height: h)
                .offset(x: 330 - cropX, y: 52)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .clipped()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12, height: 12)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12, height: 12)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 12, height: 12)
                Text("session.ts — BV-Hacks").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 12)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.code.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.white.opacity(line.hasPrefix("//") ? 0.3 : 0.62))
                        .frame(height: 26.25, alignment: .leading)
                        .fixedSize()
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 26 / 255, green: 26 / 255, blue: 32 / 255, opacity: 0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}
