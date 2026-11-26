// OWNER: workstream C (app-ui).
import SwiftUI

/// A native port of the "data rain" background: glowing streaks fall through the island and flow around the
/// pointer like water around a stone (a cylinder in potential flow, with a wake behind it). Lines that speed
/// up shift from calm cyan through violet to hot pink; a few "fire" and flash white at the head. When the
/// pointer is away, a ghost cursor wanders so the field stays alive.
///
/// Simplified from the web component: fewer lines (sized to the island), no vortex shedding, the same
/// fixed 60 Hz step and look (additive trails, a blurred bloom pass, a vignette).
struct DataRainView: View {
    let model: IslandModel
    /// The size this view fills (the island, or its left half in the split view).
    let size: CGSize
    /// The island's full width, for mapping the pointer (defaults to `size.width`).
    var islandWidth: CGFloat? = nil
    @Environment(\.notchAgentRender) private var render
    @State private var field = DataRainField()

    var body: some View {
        ZStack {
            Color(hex: 0x020308)
            if render.animated {
                TimelineView(.animation) { ctx in
                    canvas(at: ctx.date)
                }
            } else {
                canvas(at: nil)
            }
            // Vignette: darker toward the edges, and fully black under the notch so the island still meets it.
            RadialGradient(colors: [.clear, .black.opacity(0.62)], center: .center, startRadius: size.height * 0.35,
                           endRadius: max(size.width, size.height) * 0.75)
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.16),
                                   .init(color: .clear, location: 0.34)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func canvas(at date: Date?) -> some View {
        // Pointer in island coordinates (the island is centered at the top of the canvas, drawn scaled).
        let s = IslandGeometry.expandedScale
        let originX = (IslandGeometry.canvas.width - (islandWidth ?? size.width) * s) / 2
        let pointer = model.pointer.map { CGPoint(x: ($0.x - originX) / s, y: $0.y / s) }
        return Canvas { ctx, canvasSize in
            if let date {
                field.advance(to: date, size: canvasSize, pointer: pointer)
            } else {
                field.presimulate(size: canvasSize, seconds: 2.5)
            }
            // Bloom: the same strokes, blurred, underneath.
            ctx.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 6))
                bloom.opacity = 0.7
                field.draw(in: &bloom)
            }
            field.draw(in: &ctx)
        }
    }
}

/// The simulation. A reference type kept in @State, stepped from the TimelineView's clock.
final class DataRainField {
    private static let historyLength = 14
    private static let step: Double = 1.0 / 60
    private static let calm = (r: 34.0, g: 230.0, b: 255.0)
    private static let mid = (r: 138.0, g: 92.0, b: 255.0)
    private static let hot = (r: 255.0, g: 61.0, b: 154.0)

    private struct Wave { var kx, ky, om, ph, au, av: Double }
    private static func wave(_ lambda: Double, _ angle: Double, _ omega: Double, _ phase: Double, _ amp: Double) -> Wave {
        let k = 2 * .pi / lambda
        return Wave(kx: k * cos(angle), ky: k * sin(angle), om: omega, ph: phase, au: amp * sin(angle), av: -amp * cos(angle))
    }
    private static let waves = [wave(380, 0.35, 0.18, 0.7, 16), wave(620, 1.9, 0.27, 2.1, 13), wave(900, 3.4, 0.35, 4.2, 10)]

    private var size = CGSize.zero
    private var count = 0
    private var px: [Double] = [], py: [Double] = [], vx: [Double] = [], vy: [Double] = []
    private var pz: [Double] = [], v0: [Double] = [], qv: [Double] = [], fire: [Double] = []
    private var len: [Int] = []
    private var hx: [Double] = [], hy: [Double] = []
    private var head = 0
    private var simTime = 0.0
    private var last: Date?
    private var acc = 0.0
    private var rng = SplitMix(seed: 7)

    // Cursor: smoothed position and velocity, and how strongly it acts (fades in and out).
    private var cx = 0.0, cy = 0.0, vcx = 0.0, vcy = 0.0, influence = 0.0
    private var hadSource = false

    // MARK: Driving

    func advance(to date: Date, size: CGSize, pointer: CGPoint?) {
        prepare(size)
        guard let last else {
            self.last = date
            presimulate(size: size, seconds: 2.5)
            return
        }
        acc += min(0.05, max(0, date.timeIntervalSince(last)))
        self.last = date
        var n = 0
        while acc >= Self.step && n < 3 {
            simulate(pointer: pointer)
            acc -= Self.step
            n += 1
        }
        if n == 3 { acc = 0 }
    }

    func presimulate(size: CGSize, seconds: Double) {
        prepare(size)
        guard simTime == 0 else { return }
        for _ in 0..<Int(seconds / Self.step) { simulate(pointer: nil) }
    }

    private func prepare(_ s: CGSize) {
        guard s != size, s.width > 1, s.height > 1 else { return }
        let first = size == .zero
        size = s
        let n = min(900, max(160, Int(s.width * s.height / 210)))
        if n != count {
            count = n
            px = .init(repeating: 0, count: n); py = px; vx = px; vy = px; pz = px; v0 = px; qv = px; fire = px
            len = .init(repeating: 0, count: n)
            hx = .init(repeating: 0, count: n * Self.historyLength); hy = hx
            for i in 0..<n { seed(i, uniform: true) }
        } else if !first {
            for i in 0..<n where px[i] > s.width + 60 || py[i] > s.height + 30 { seed(i, uniform: false) }
        }
        if first { cx = s.width / 2; cy = s.height / 2 }
    }

    private func seed(_ i: Int, uniform: Bool) {
        let x = uniform ? rng.next() * size.width : -30 + rng.next() * (size.width + 60)
        let y = uniform ? rng.next() * size.height : -20 - rng.next() * 50
        let z = 0.35 + 0.65 * rng.next()
        let nominal = 45 + 60 * z * z   // slower than the full-screen original: the island is small
        pz[i] = z; v0[i] = nominal; len[i] = 7 + Int(rng.next() * 7)
        px[i] = x; py[i] = y; vx[i] = 0; vy[i] = nominal; qv[i] = 1; fire[i] = 0
        let base = i * Self.historyLength
        for k in 0..<Self.historyLength { hx[base + k] = x; hy[base + k] = y }
    }

    // MARK: Physics (one fixed step)

    private func simulate(pointer: CGPoint?) {
        let step = Self.step, L = Self.historyLength
        head = (head + 1) % L
        simTime += step

        // The real pointer, else a ghost wandering a Lissajous path.
        let target: (Double, Double)
        if let pointer {
            target = (pointer.x, pointer.y)
        } else {
            target = (size.width * (0.5 + 0.34 * sin(0.37 * simTime)), size.height * (0.55 + 0.25 * sin(0.53 * simTime + 1.2)))
        }
        let source = pointer != nil
        let kCursor = 1 - exp(-step * 18), kVel = 1 - exp(-step * 10)
        if source && !hadSource && influence < 0.05 {
            cx = target.0; cy = target.1; vcx = 0; vcy = 0
        } else {
            let pcx = cx, pcy = cy
            cx += (target.0 - cx) * kCursor
            cy += (target.1 - cy) * kCursor
            vcx += ((cx - pcx) / step - vcx) * kVel
            vcy += ((cy - pcy) / step - vcy) * kVel
        }
        hadSource = source
        // The ghost pushes gently; the real pointer fully.
        let goal = source ? 1.0 : 0.55
        influence += (goal - influence) * (1 - exp(-step / (goal > influence ? 0.06 : 0.2)))
        let infl = influence
        let vcMag = (vcx * vcx + vcy * vcy).squareRoot()
        let a = 30 + min(vcMag * 0.02, 22)  // obstacle radius

        let ph = Self.waves.map { $0.om * simTime + $0.ph }
        let kRelax = 1 - exp(-step / 0.12), kQ = 1 - exp(-step * 8)
        let fireP = 0.03 * step, fireDecay = exp(-step / 0.45)

        for i in 0..<count {
            let x0 = px[i], y0 = py[i], z = pz[i], v0e = v0[i]
            var tx = 0.0, ty = v0e
            for (w, p) in zip(Self.waves, ph) {
                let c = cos(w.kx * x0 + w.ky * y0 + p)
                tx += w.au * c * z
                ty += w.av * c * z
            }

            let aE = a * (0.55 + 0.45 * z)
            let rx = x0 - cx, ry = y0 - cy
            let d2 = rx * rx + ry * ry
            var pertX = 0.0, pertY = 0.0, deficit = 0.0
            var ux0 = -vcx, uy0 = v0e - vcy
            var U = (ux0 * ux0 + uy0 * uy0).squareRoot()
            if U > 1e-3 {
                if U > 900 { ux0 *= 900 / U; uy0 *= 900 / U; U = 900 }
                let ex = ux0 / U, ey = uy0 / U
                let s = rx * ex + ry * ey, n = -rx * ey + ry * ex
                if s > 0 && s < 12 * aE {  // the wake behind the stone
                    let nn = n / (0.9 * aE + 0.2 * s)
                    deficit = 0.55 * exp(-s / (3 * aE)) * exp(-nn * nn)
                }
                let near = 9 * aE
                if d2 < near * near {  // flow around a cylinder (perturbation part)
                    let rho2 = max(s * s + n * n, aE * aE * 0.64)
                    let k = aE * aE / (rho2 * rho2)
                    let ds = -U * k * (s * s - n * n), dn = -U * k * 2 * s * n
                    var win = 1.0
                    let inner = 5 * aE
                    if d2 > inner * inner {
                        let t = (d2.squareRoot() - inner) / (4 * aE)
                        win = 1 - t * t * (3 - 2 * t)
                    }
                    pertX = (ds * ex - dn * ey) * win
                    pertY = (ds * ey + dn * ex) * win
                }
            }
            let keep = 1 - deficit * infl
            tx = tx * keep + pertX * infl
            ty = ty * keep + pertY * infl

            var ux = vx[i] + (tx - vx[i]) * kRelax
            var uy = vy[i] + (ty - vy[i]) * kRelax
            let sp2 = ux * ux + uy * uy
            if sp2 > 810_000 { let sc = 900 / sp2.squareRoot(); ux *= sc; uy *= sc }
            var x = x0 + ux * step, y = y0 + uy * step

            // Never enter the stone.
            if infl > 0.05 {
                let aP = aE * min(1, infl * 1.5)
                let qx = x - cx, qy = y - cy, q2 = qx * qx + qy * qy
                if q2 < (0.98 * aP) * (0.98 * aP) {
                    let rr = q2.squareRoot()
                    let nx = rr < 1e-3 ? 0 : qx / rr, ny = rr < 1e-3 ? 1 : qy / rr
                    x = cx + nx * aP; y = cy + ny * aP
                    let vn = (ux - vcx) * nx + (uy - vcy) * ny
                    if vn < 0 { ux -= vn * nx; uy -= vn * ny }
                }
            }
            vx[i] = ux; vy[i] = uy; px[i] = x; py[i] = y

            if y > size.height + 30 || x < -60 || x > size.width + 60 || y < -300 {
                seed(i, uniform: false)
                continue
            }
            qv[i] += ((ux * ux + uy * uy).squareRoot() / v0e - qv[i]) * kQ
            if rng.next() < fireP { fire[i] = 1 } else { let f = fire[i] * fireDecay; fire[i] = f < 0.01 ? 0 : f }
            hx[i * L + head] = x
            hy[i * L + head] = y
        }
    }

    // MARK: Drawing

    func draw(in ctx: inout GraphicsContext) {
        guard count > 0 else { return }
        let L = Self.historyLength
        ctx.blendMode = .plusLighter
        let colors = [Self.calm, Self.mid, Self.hot]
        let baseAlpha = [0.22, 0.34, 0.5], baseWidth = [0.7, 0.9, 1.2]
        let ageBuckets = 4
        // Group lines by depth x speed bucket, then stroke each age band once.
        var groups = Array(repeating: [Int](), count: 6)
        for i in 0..<count {
            var b = qv[i] < 1.25 ? 0 : qv[i] < 1.85 ? 1 : 2
            if fire[i] > 0.35 && b < 2 { b += 1 }
            groups[(pz[i] < 0.62 ? 0 : 3) + b].append(i)
        }
        for g in 0..<6 where !groups[g].isEmpty {
            let depth = g < 3 ? 0.0 : 1.0, bucket = g % 3, c = colors[bucket]
            for ab in 0..<ageBuckets {
                let falloff = pow(1 - (Double(ab) + 0.5) / Double(ageBuckets), 1.5)
                let alpha = min(0.95, baseAlpha[bucket] * (depth == 0 ? 0.55 : 1) * falloff * 1.7)
                let width = min(1.3, max(0.6, baseWidth[bucket] * (depth == 0 ? 0.75 : 1) * (1 - 0.45 * Double(ab) / Double(ageBuckets))))
                let k0 = ab * (L / ageBuckets), k1 = k0 + L / ageBuckets
                var path = Path()
                for i in groups[g] {
                    let segs = len[i] - 1
                    guard k0 < segs else { continue }
                    let base = i * L
                    var idx = (head - k0 + L) % L
                    path.move(to: CGPoint(x: hx[base + idx], y: hy[base + idx]))
                    for _ in k0..<min(k1, segs) {
                        idx = idx == 0 ? L - 1 : idx - 1
                        path.addLine(to: CGPoint(x: hx[base + idx], y: hy[base + idx]))
                    }
                }
                ctx.stroke(path, with: .color(Color(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: alpha)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        // White-hot heads on the fastest and the firing lines.
        let prev = head == 0 ? L - 1 : head - 1
        for depth in 0..<2 {
            var path = Path()
            for b in 1..<3 {
                for i in groups[depth * 3 + b] where b == 2 || fire[i] > 0.5 {
                    path.move(to: CGPoint(x: hx[i * L + head], y: hy[i * L + head]))
                    path.addLine(to: CGPoint(x: hx[i * L + prev], y: hy[i * L + prev]))
                }
            }
            ctx.stroke(path, with: .color(Color(.sRGB, red: 234 / 255, green: 252 / 255, blue: 1, opacity: depth == 0 ? 0.5 : 0.85)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }
}

/// Small deterministic RNG (the web version's mulberry32 plays the same role).
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
