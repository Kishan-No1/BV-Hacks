// OWNER: workstream C (app-ui).
import NodCore
import SwiftUI

/// The island outline: rounded bottom corners plus the outward 10 pt "shoulder" curves at the top corners
/// (prototype `.shoulder.l/.r`). The shoulders are drawn outside `rect` so the frame stays the island body.
struct IslandShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat = IslandGeometry.shoulder

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
        let r = max(0, min(radius, w / 2, h - shoulder))
        let s = shoulder
        let k: CGFloat = 0.5523
        var p = Path()
        p.move(to: CGPoint(x: x0 - s, y: y0))
        p.addLine(to: CGPoint(x: x0 + w + s, y: y0))
        // Right shoulder: concave quarter circle centered at (w + s, s).
        p.addCurve(to: CGPoint(x: x0 + w, y: y0 + s),
                   control1: CGPoint(x: x0 + w + s - s * k, y: y0),
                   control2: CGPoint(x: x0 + w, y: y0 + s - s * k))
        p.addLine(to: CGPoint(x: x0 + w, y: y0 + h - r))
        p.addCurve(to: CGPoint(x: x0 + w - r, y: y0 + h),
                   control1: CGPoint(x: x0 + w, y: y0 + h - r + r * k),
                   control2: CGPoint(x: x0 + w - r + r * k, y: y0 + h))
        p.addLine(to: CGPoint(x: x0 + r, y: y0 + h))
        p.addCurve(to: CGPoint(x: x0, y: y0 + h - r),
                   control1: CGPoint(x: x0 + r - r * k, y: y0 + h),
                   control2: CGPoint(x: x0, y: y0 + h - r + r * k))
        p.addLine(to: CGPoint(x: x0, y: y0 + s))
        // Left shoulder: concave quarter circle centered at (-s, s).
        p.addCurve(to: CGPoint(x: x0 - s, y: y0),
                   control1: CGPoint(x: x0, y: y0 + s - s * k),
                   control2: CGPoint(x: x0 - s + s * k, y: y0))
        p.closeSubpath()
        return p
    }
}

/// The whole island at the top center of the fixed canvas. The canvas never resizes; the island springs inside it.
struct IslandCanvas: View {
    let model: IslandModel

    var body: some View {
        let state = model.displayedState
        let size = model.size(for: state)
        let radius = IslandGeometry.cornerRadius(for: state)
        ZStack(alignment: .top) {
            IslandGlow(risk: state.glowRisk, expanded: state.isExpanded, size: size, radius: radius)
            IslandBody(model: model, state: state, size: size, radius: radius)
        }
        .frame(width: IslandGeometry.canvas.width, height: IslandGeometry.canvas.height, alignment: .top)
    }
}

struct IslandBody: View {
    let model: IslandModel
    let state: IslandState
    let size: CGSize
    let radius: CGFloat

    var body: some View {
        let expanded = state.isExpanded
        let shape = IslandShape(radius: radius)
        ZStack(alignment: .top) {
            IslandBackground(expanded: expanded, height: size.height, radius: radius)
            GlassEdge(risk: state.glowRisk, radius: radius)
                .opacity(expanded ? 1 : 0)
                .zIndex(state.glassOverContent ? 3 : 1)
            ZStack(alignment: .top) {
                IslandContent(model: model, state: state)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .id(state.identity)
                    .transition(.islandSwap)
            }
            .zIndex(2)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// `.island .bgs`: black, opening to rgba(0,0,0,.38) at the bottom edge when expanded.
struct IslandBackground: View {
    let expanded: Bool
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        let h = max(height, 1)
        let a = max(0, min(1, (h - 78) / h)), b = max(a, min(1, (h - 36) / h))
        let gradient = LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: a),
            .init(color: .black.opacity(expanded ? 0.7 : 1), location: b),
            .init(color: .black.opacity(expanded ? 0.38 : 1), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        IslandShape(radius: radius).fill(gradient)
    }
}

/// The Liquid Glass bottom edge (~74 pt). Native `.glassEffect` when live; a gradient fallback always
/// sits on top for the highlights, and alone in snapshots (glass does not render offscreen).
struct GlassEdge: View {
    let risk: RiskLevel?
    let radius: CGFloat
    @Environment(\.nodRender) private var render

    static let height: CGFloat = 74

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = Self.height
            ZStack {
                if render.nativeGlass {
                    Rectangle().fill(Color.clear)
                        .glassEffect(.clear, in: Rectangle())
                }
                // linear-gradient(180deg, rgba(255,255,255,0) 0%, .035 60%, .07 100%)
                LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(risk == nil ? 0.035 : 0.02), location: 0.6),
                    .init(color: .white.opacity(risk == nil ? 0.07 : 0.05), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                if let risk {
                    // radial-gradient(90% 160% at 50% 135%, tint, transparent 70%): an ellipse with radii
                    // 0.63 w x 1.12 h centered 35% of the band below its bottom edge.
                    let rx = w * 0.9 * 0.7, ry = h * 1.6 * 0.7
                    RadialGradient(colors: [Self.tint(risk), Self.tint(risk).opacity(0)], center: .center,
                                   startRadius: 0, endRadius: rx)
                        .frame(width: rx * 2, height: rx * 2)
                        .scaleEffect(x: 1, y: ry / rx)
                        .position(x: w / 2, y: h * 1.35)
                }
                // inset 0 -14px 18px -14px rgba(255,255,255,.22): a soft inner glow along the bottom.
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: w, height: h)
            .overlay {
                // inset 0 -1.5px 0 rgba(255,255,255,.30) along the bottom curve, 1.5px .10 on the sides.
                Path { p in
                    let r = min(radius, h)
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: h - r))
                    p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w - r, y: h))
                    p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 3)
                Path { p in
                    let r = min(radius, h)
                    p.move(to: CGPoint(x: 0, y: h - r - 6))
                    p.addLine(to: CGPoint(x: 0, y: h - r))
                    p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w - r, y: h))
                    p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w, y: h - r - 6))
                }
                .stroke(Color.white.opacity(0.30), lineWidth: 3)
            }
            .clipped()
            // mask-image: linear-gradient(180deg, transparent 0%, #000 55%)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    static func tint(_ risk: RiskLevel) -> Color {
        switch risk {
        case .high: return Theme.red.opacity(0.42)
        case .review: return Theme.amber.opacity(0.28)
        case .low: return .clear
        }
    }
}

/// The soft colored glow (CSS box-shadows with negative spread). Cut out under the island, never an outline.
struct IslandGlow: View {
    let risk: RiskLevel?
    let expanded: Bool
    let size: CGSize
    let radius: CGFloat

    private struct Layer {
        var color: Color, dy: CGFloat, blur: CGFloat, spread: CGFloat
    }

    private var layers: [Layer] {
        switch risk {
        case .high?:
            return [Layer(color: Theme.red.opacity(0.75), dy: 30, blur: 70, spread: -22),
                    Layer(color: Theme.red.opacity(0.45), dy: 12, blur: 40, spread: -14)]
        case .review?:
            return [Layer(color: Theme.amber.opacity(0.5), dy: 30, blur: 70, spread: -24),
                    Layer(color: Theme.amber.opacity(0.3), dy: 12, blur: 36, spread: -16)]
        default:
            return expanded ? [Layer(color: .black.opacity(0.6), dy: 22, blur: 50, spread: -18)] : []
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, l in
                RoundedRectangle(cornerRadius: max(0, radius + l.spread), style: .continuous)
                    .fill(l.color)
                    .frame(width: max(0, size.width + 2 * l.spread), height: max(0, size.height + 2 * l.spread))
                    .offset(y: -l.spread + l.dy)
                    .blur(radius: l.blur / 2)
            }
        }
        .frame(width: IslandGeometry.canvas.width, height: IslandGeometry.canvas.height, alignment: .top)
        .reverseMask(alignment: .top) {
            IslandShape(radius: radius).frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }
}

/// Content swap: blur 5 pt + scale from 0.94 + opacity, laid out at the final size so nothing reflows.
struct IslandSwapModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 5 : 0)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var islandSwap: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(active: IslandSwapModifier(active: true), identity: IslandSwapModifier(active: false))
                .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.45).delay(0.09)),
            removal: AnyTransition.modifier(active: IslandSwapModifier(active: true), identity: IslandSwapModifier(active: false))
                .animation(.easeIn(duration: 0.1))
        )
    }
}

/// Picks the content view for a state.
struct IslandContent: View {
    let model: IslandModel
    let state: IslandState

    var body: some View {
        switch state {
        case .idle:
            Color.clear
        case .working:
            CompactWorking()
        case .attention:
            CompactAttention()
        case .toast(let kind):
            CompactToast(kind: kind)
        case .progress:
            ProgressContent(model: model)
        case .request(let r):
            RequestContent(model: model, request: r)
        }
    }
}
