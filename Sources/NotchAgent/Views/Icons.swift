// OWNER: workstream C (app-ui).
import SwiftUI

/// The pixel-art Claude Code mascot, from the prototype's `clawd()` rects (viewBox 18 x 13).
struct ClawdShape: Shape {
    static let rects: [CGRect] = [
        CGRect(x: 3, y: 0, width: 12, height: 2.5),
        CGRect(x: 3, y: 2.5, width: 2, height: 2.5),
        CGRect(x: 6, y: 2.5, width: 6, height: 2.5),
        CGRect(x: 13, y: 2.5, width: 2, height: 2.5),
        CGRect(x: 1, y: 5, width: 16, height: 2.5),
        CGRect(x: 3, y: 7.5, width: 12, height: 2.5),
        CGRect(x: 4, y: 10, width: 1, height: 3),
        CGRect(x: 6, y: 10, width: 1, height: 3),
        CGRect(x: 11, y: 10, width: 1, height: 3),
        CGRect(x: 13, y: 10, width: 1, height: 3),
    ]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 18, sy = rect.height / 13
        var p = Path()
        for r in Self.rects {
            p.addRect(CGRect(x: rect.minX + r.minX * sx, y: rect.minY + r.minY * sy, width: r.width * sx, height: r.height * sy))
        }
        return p
    }
}

struct Clawd: View {
    var width: CGFloat = 20
    var color: Color = Theme.orange
    /// Wears the holiday nightcap (the collapsed island's mascot).
    var festive: Bool = false

    var body: some View {
        ClawdShape()
            .fill(color)
            .frame(width: width, height: (width * 13 / 18).rounded())
            .overlay(alignment: .topLeading) {
                if festive { Nightcap(width: width) }
            }
            .accessibilityLabel("Claude Code")
    }
}

/// The prototype's inline SVG icons (24 x 24 viewBox), ported to paths.
enum IconPath {
    static func scaled(_ rect: CGRect, _ build: (inout Path, (CGFloat, CGFloat) -> CGPoint) -> Void) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2, oy = rect.minY + (rect.height - 24 * s) / 2
        var p = Path()
        build(&p) { x, y in CGPoint(x: ox + x * s, y: oy + y * s) }
        return p
    }
}

/// `I.check` / `ok`: M4.5 12.5 l5 5 L19.5 6.5 (stroke 3).
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(4.5, 12.5)); p.addLine(to: pt(9.5, 17.5)); p.addLine(to: pt(19.5, 6.5))
        }
    }
}

struct CheckIcon: View {
    var size: CGFloat = 14
    var color: Color = Theme.orange
    var body: some View {
        CheckShape()
            .stroke(color, style: StrokeStyle(lineWidth: 3 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// `I.play` (filled).
struct PlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(7, 4.8))
            p.addLine(to: pt(7, 19.2))
            p.addCurve(to: pt(8.6, 20.0), control1: pt(7, 20.0), control2: pt(7.9, 20.5))
            p.addLine(to: pt(19.6, 12.8))
            p.addCurve(to: pt(19.6, 11.2), control1: pt(20.2, 12.4), control2: pt(20.2, 11.6))
            p.addLine(to: pt(8.6, 4.0))
            p.addCurve(to: pt(7, 4.8), control1: pt(7.9, 3.5), control2: pt(7, 4))
            p.closeSubpath()
        }
    }
}

/// `I.doc` (filled, even-odd: folded corner and two text lines are holes).
struct DocShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            let k: CGFloat = 0.5523 * 2
            p.move(to: pt(6, 2)); p.addLine(to: pt(14, 2)); p.addLine(to: pt(20, 8)); p.addLine(to: pt(20, 20))
            p.addCurve(to: pt(18, 22), control1: pt(20, 20 + k), control2: pt(18 + k, 22))
            p.addLine(to: pt(6, 22))
            p.addCurve(to: pt(4, 20), control1: pt(6 - k, 22), control2: pt(4, 20 + k))
            p.addLine(to: pt(4, 4))
            p.addCurve(to: pt(6, 2), control1: pt(4, 4 - k), control2: pt(6 - k, 2))
            p.closeSubpath()
            p.move(to: pt(13, 3.5)); p.addLine(to: pt(13, 9)); p.addLine(to: pt(18.5, 9)); p.closeSubpath()
            p.addRect(CGRect(origin: pt(8, 13), size: CGSize(width: pt(16, 0).x - pt(8, 0).x, height: pt(0, 14.6).y - pt(0, 13).y)))
            p.addRect(CGRect(origin: pt(8, 17), size: CGSize(width: pt(16, 0).x - pt(8, 0).x, height: pt(0, 18.6).y - pt(0, 17).y)))
        }
    }
}

/// `I.list` (stroke 2): a checked box, a circle, two lines.
struct ListShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            let o = pt(3, 4), e = pt(9, 10)
            p.addRoundedRect(in: CGRect(x: o.x, y: o.y, width: e.x - o.x, height: e.y - o.y),
                             cornerSize: CGSize(width: (e.x - o.x) * 1.6 / 6, height: (e.x - o.x) * 1.6 / 6))
            p.move(to: pt(4.6, 7)); p.addLine(to: pt(5.7, 8.1)); p.addLine(to: pt(7.6, 6))
            let c = pt(6, 17), r = pt(9, 17).x - c.x
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            p.move(to: pt(13, 7)); p.addLine(to: pt(21, 7))
            p.move(to: pt(13, 17)); p.addLine(to: pt(21, 17))
        }
    }
}

/// `I.shield` (stroke 2).
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(12, 3)); p.addLine(to: pt(19.5, 6)); p.addLine(to: pt(19.5, 11.5))
            p.addCurve(to: pt(12, 21), control1: pt(19.5, 16.1), control2: pt(16.3, 19.8))
            p.addCurve(to: pt(4.5, 11.5), control1: pt(7.7, 19.8), control2: pt(4.5, 16.1))
            p.addLine(to: pt(4.5, 6)); p.closeSubpath()
            p.move(to: pt(9, 12)); p.addLine(to: pt(11, 14)); p.addLine(to: pt(15, 10))
        }
    }
}

struct StrokeIcon<S: Shape>: View {
    let shape: S
    var size: CGFloat
    var color: Color
    var body: some View {
        shape
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// The red ✕ for failed steps.
struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(6, 6)); p.addLine(to: pt(18, 18))
            p.move(to: pt(18, 6)); p.addLine(to: pt(6, 18))
        }
    }
}
