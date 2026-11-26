// OWNER: workstream C (app-ui).
import NotchAgentCore
import SwiftUI

/// CSS `cubic-bezier(x1, y1, x2, y2)` timing function.
struct CubicBezier {
    let x1, y1, x2, y2: Double

    static let easeInOut = CubicBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let wave = CubicBezier(x1: 0.45, y1: 0, x2: 0.55, y2: 1)

    func callAsFunction(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        // Solve bx(t) = x with Newton's method, then return by(t).
        var t = x
        for _ in 0..<8 {
            let cx = sample(t, x1, x2) - x
            let d = derivative(t, x1, x2)
            if abs(cx) < 1e-6 || abs(d) < 1e-6 { break }
            t -= cx / d
        }
        t = min(1, max(0, t))
        return sample(t, y1, y2)
    }

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func derivative(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }
}

/// Drives looping animations from a clock; frozen at t = 0 in snapshots (the resting state).
struct AnimationClock<Content: View>: View {
    @Environment(\.notchAgentRender) private var render
    @ViewBuilder var content: (Double) -> Content

    var body: some View {
        if render.animated {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                content(ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(0)
        }
    }
}

/// The 4-bar wave: `@keyframes wave { 0%,100% { height:4px } 50% { height:13px } }`, 1 s, staggered.
struct Wave: View {
    var color: Color = Theme.orange
    static let delays: [Double] = [0.15, 0.55, 0.3, 0.75]

    static func height(bar: Int, time: Double) -> CGFloat {
        let tau = (time + delays[bar]).truncatingRemainder(dividingBy: 1)
        let p = tau < 0.5 ? CubicBezier.wave(tau / 0.5) : 1 - CubicBezier.wave((tau - 0.5) / 0.5)
        return 4 + 9 * p
    }

    var body: some View {
        AnimationClock { t in
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 3, height: Self.height(bar: i, time: t))
                }
            }
            .frame(height: 13)
        }
    }
}

/// `.pulse { animation: pulse 1.3s ease-in-out infinite } @keyframes pulse { 50% { opacity:.35 } }`.
struct Pulse<Content: View>: View {
    @ViewBuilder var content: () -> Content

    static func opacity(time: Double) -> Double {
        let tau = time.truncatingRemainder(dividingBy: 1.3) / 1.3
        let p = tau < 0.5 ? CubicBezier.easeInOut(tau / 0.5) : 1 - CubicBezier.easeInOut((tau - 0.5) / 0.5)
        return 1 - 0.65 * p
    }

    var body: some View {
        AnimationClock { t in content().opacity(Self.opacity(time: t)) }
    }
}

/// `.ears`: 32 tall, padding 0 13 0 14, content at both ends of the pill.
struct Ears<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { left() }
            Spacer(minLength: 0)
            HStack(spacing: 6) { right() }
        }
        .font(Theme.font(12.5, .semibold))
        .tracking(Theme.em(-0.01, 12.5))
        .padding(.leading, 14)
        .padding(.trailing, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompactWorking: View {
    var body: some View {
        Ears { Kishu(width: 22.5).offset(y: 2.5) } right: { Wave() }
    }
}

struct CompactAttention: View {
    var body: some View {
        Ears {
            Kishu(width: 22.5).offset(y: 2.5)
                .overlay(alignment: .topTrailing) {
                    // .badge-dot::after: 6px amber, right -3 top -3, 1.5px black ring
                    Circle().fill(Theme.amber)
                        .frame(width: 6, height: 6)
                        .background(Circle().fill(Color.black).frame(width: 9, height: 9))
                        .offset(x: 3, y: -3)
                }
        } right: {
            Pulse {
                Text("●").font(Theme.font(11)).foregroundStyle(Theme.amber)
            }
        }
    }
}

struct CompactToast: View {
    let kind: Toast.Kind

    var body: some View {
        Ears { Kishu(width: 22.5).offset(y: 2.5) } right: {
            switch kind {
            case .done:
                Text("Done").fontWeight(.medium).foregroundStyle(Theme.ink2)
                CheckIcon(size: 15, color: Theme.green)
            case .allowed:
                Text("Allowed").fontWeight(.medium).foregroundStyle(Theme.ink2)
                CheckIcon(size: 15, color: Theme.green)
            case .autoAllowed:
                Text("Auto-allowed").fontWeight(.medium).foregroundStyle(Theme.ink2)
                CheckIcon(size: 15, color: Theme.green)
            case .denied:
                Text("Denied").fontWeight(.medium).foregroundStyle(Theme.ink2)
                Text("✕").font(Theme.font(13, .heavy)).foregroundStyle(Theme.red)
            }
        }
    }
}
