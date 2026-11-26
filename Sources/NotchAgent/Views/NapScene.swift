// OWNER: workstream C (app-ui).
import NotchAgentCore
import SwiftUI

/// Nothing has run for a while: Progress shows Claude asleep instead of stale steps.
enum Quiet {
    /// How long every session must have been silent (and none working or waiting on you).
    static let after: TimeInterval = 2 * 60

    static func isQuiet(_ sessions: [Session], now: Date) -> Bool {
        if sessions.contains(where: { $0.status == .working || $0.status == .needsYou }) { return false }
        guard let last = sessions.map(\.lastEventAt).max() else { return true }
        return now.timeIntervalSince(last) > after
    }
}

/// Re-evaluates `content` every few seconds (frozen in snapshots), for states that change with time.
struct SlowClock<Content: View>: View {
    @Environment(\.notchAgentRender) private var render
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let now = render.frozenNow {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in content(ctx.date) }
        }
    }
}

/// The empty state: the Claude mascot asleep (eyes shut, breathing slowly), "z"s drifting up, and a line of text.
struct NapScene: View {
    var mascot: CGFloat = 68

    var body: some View {
        VStack(spacing: 12) {
            AnimationClock { t in
                ZStack(alignment: .topTrailing) {
                    SleepingKishu(width: mascot)
                        // Slow breathing: a gentle rise and fall from the feet.
                        .scaleEffect(x: 1 + 0.015 * sin(t * 2 * .pi / 3.2),
                                     y: 1 - 0.045 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2)), anchor: .bottom)
                    Snores(time: t)
                        .offset(x: mascot * 0.42, y: -mascot * 0.36)
                }
                .frame(width: mascot * 1.9, height: mascot * 1.15, alignment: .bottom)
            }
            VStack(spacing: 4) {
                Text("Nothing's running right now")
                    .font(Theme.font(15.5, .bold))
                    .tracking(Theme.em(-0.015, 15.5))
                    .foregroundStyle(Theme.Vibe.claudeName)
                Text(mascot < 66 ? "Kishu is napping. Start a chat to wake him." : "Kishu is curled up for a nap. Start a chat to wake him.")
                    .font(Theme.font(12.5, .semibold))
                    .foregroundStyle(Theme.Vibe.label)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The mascot asleep for the holidays: eyes shut, a red nightcap with a white pom-pom flopping to the left
/// (away from the z's), and a little plaid blanket tucked over its legs.
struct SleepingKishu: View {
    let width: CGFloat

    static let capRed = Color(hex: 0xE5484D)
    static let capShade = Color(hex: 0xB8323A)
    static let fluff = Color(hex: 0xF6F3EE)
    static let pine = Color(hex: 0x2F9E6E)
    static let pineDark = Color(hex: 0x1F7A53)

    var body: some View {
        let h = (width * 13 / 18).rounded()
        let sx = width / 18, sy = h / 13
        KishuSprite(width: width, asleep: true)
        .frame(width: width, height: h)
        .overlay(alignment: .topLeading) {
            // Drawn in the mascot's 18 x 13 grid, with room above and to the left for the cap.
            let padX: CGFloat = 5, padY: CGFloat = 7
            Canvas { ctx, _ in
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x + padX) * sx, y: (y + padY) * sy) }
                func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ hh: CGFloat) -> CGRect {
                    CGRect(x: (x + padX) * sx, y: (y + padY) * sy, width: w * sx, height: hh * sy)
                }

                // Blanket over the legs: green plaid with red stripes and a fluffy hem along the top.
                let blanket = Path(roundedRect: rect(0.2, 9.9, 17.6, 3.6), cornerRadius: 1.2 * sx)
                ctx.fill(blanket, with: .linearGradient(Gradient(colors: [Self.pine, Self.pineDark]),
                                                        startPoint: pt(0, 9.9), endPoint: pt(0, 13.5)))
                ctx.drawLayer { plaid in
                    plaid.clip(to: blanket)
                    for x in stride(from: 2.0, to: 18, by: 4) {
                        plaid.fill(Path(rect(CGFloat(x), 9.9, 1.1, 3.6)), with: .color(Self.capRed.opacity(0.75)))
                    }
                    plaid.fill(Path(rect(0, 11.5, 18, 0.8)), with: .color(Self.capRed.opacity(0.6)))
                    plaid.fill(Path(rect(0, 12.8, 18, 0.4)), with: .color(Self.fluff.opacity(0.35)))
                }
                ctx.fill(Path(roundedRect: rect(0, 9.4, 18, 1.2), cornerRadius: 0.6 * sx), with: .color(Self.fluff))
                for x in stride(from: 1.2, to: 17.5, by: 2.2) {
                    ctx.fill(Path(ellipseIn: rect(CGFloat(x), 9.75, 0.5, 0.5)), with: .color(Self.capRed.opacity(0.8)))
                }

            }
            .frame(width: (18 + padX + 2) * sx, height: (13 + padY + 1) * sy)
            .offset(x: -padX * sx, y: -padY * sy)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { Nightcap(width: width) }
        .shadow(color: Color(hex: 0xFECEAF).opacity(0.3), radius: 10)
        .accessibilityLabel("Kishu, asleep in a nightcap under a blanket")
    }
}

/// The holiday nightcap, drawn over a mascot `width` points wide (in its 18 x 13 grid): red with a soft shine,
/// a fluffy white band, and a pom-pom flopping to the left. Overlay it at the mascot's top-leading corner.
struct Nightcap: View {
    let width: CGFloat

    var body: some View {
        let h = (width * 13 / 18).rounded()
        let sx = width / 18, sy = h / 13
        let padX: CGFloat = 5, padY: CGFloat = 7
        Canvas { ctx, _ in
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x + padX) * sx, y: (y + padY) * sy) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ hh: CGFloat) -> CGRect {
                CGRect(x: (x + padX) * sx, y: (y + padY) * sy, width: w * sx, height: hh * sy)
            }
            // Nightcap: from the top of the head, flopping left and down, with a white band and pom-pom.
            var cap = Path()
            cap.move(to: pt(3.2, 0.4))
            cap.addCurve(to: pt(-2.2, -0.2), control1: pt(4.5, -5.5), control2: pt(-0.5, -6.2))
            cap.addCurve(to: pt(14.8, 0.4), control1: pt(2.5, -4.8), control2: pt(11.5, -6.8))
            cap.closeSubpath()
            ctx.fill(cap, with: .linearGradient(Gradient(colors: [SleepingKishu.capRed, SleepingKishu.capShade]),
                                                startPoint: pt(9, -5.5), endPoint: pt(2, 0.5)))
            // A soft highlight along the crown.
            var shine = Path()
            shine.move(to: pt(8.5, -4.6))
            shine.addQuadCurve(to: pt(13.2, -0.6), control: pt(12.4, -4.2))
            ctx.stroke(shine, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 0.55 * sx, lineCap: .round))
            // Fluffy band and pom-pom.
            ctx.fill(Path(roundedRect: rect(2.4, -0.7, 13.2, 1.9), cornerRadius: 0.95 * sx), with: .color(SleepingKishu.fluff))
            ctx.fill(Path(ellipseIn: rect(-3.6, -1.4, 2.9, 2.9)), with: .color(SleepingKishu.fluff))
            ctx.fill(Path(ellipseIn: rect(-2.9, -0.9, 1.0, 1.0)), with: .color(.white))
        }
        .frame(width: (18 + padX + 2) * sx, height: (13 + padY + 1) * sy)
        .offset(x: -padX * sx, y: -padY * sy)
        .allowsHitTesting(false)
    }
}

/// The small version beside the song title: the mascot asleep with its z's, nothing else.
struct MiniNap: View {
    var body: some View {
        AnimationClock { t in
            ZStack(alignment: .topTrailing) {
                SleepingKishu(width: 38)
                    .scaleEffect(x: 1 + 0.015 * sin(t * 2 * .pi / 3.2),
                                 y: 1 - 0.05 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2)), anchor: .bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Snores(time: t)
                    .scaleEffect(0.75, anchor: .bottomLeading)
                    .offset(x: 36, y: 2)
            }
            .frame(width: 65, height: 50, alignment: .bottomLeading)
        }
        .accessibilityLabel("Nothing's running in Claude; Kishu is napping")
    }
}

/// Three "z"s rising and fading in turn.
struct Snores: View {
    let time: Double
    static let period = 2.7

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { i in
                let p = ((time / Self.period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 9 + CGFloat(p) * 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Vibe.claudeName)
                    .opacity(p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85)
                    .offset(x: CGFloat(p) * 16 + CGFloat(sin(p * .pi * 2)) * 2, y: -CGFloat(p) * 24)
            }
        }
        .frame(width: 30, height: 30, alignment: .bottomLeading)
    }
}
