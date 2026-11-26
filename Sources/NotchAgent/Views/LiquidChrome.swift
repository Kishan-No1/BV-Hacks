// OWNER: workstream C (app-ui).
import CoreGraphics
import SwiftUI

/// A native port of the "liquid chrome" background: a pool of molten metal that slowly folds over itself and
/// mirrors a studio of soft coloured lights; the pointer drops a ripple into it.
///
/// The web version is a WebGL fragment shader. This build has no Metal compiler (Command Line Tools only),
/// so the same math runs on the CPU at a low resolution (the surface is smooth, so it scales up cleanly),
/// with two changes for speed: an integer hash instead of `sin` for the noise, and surface normals taken
/// from neighbouring height samples instead of three extra height evaluations per pixel.
struct LiquidChromeView: View {
    let model: IslandModel
    /// The size this view fills (the island, or its left half in the split view).
    let size: CGSize
    /// The island's full width, for mapping the pointer (defaults to `size.width`).
    var islandWidth: CGFloat? = nil
    @Environment(\.notchAgentRender) private var render
    @State private var pool = LiquidChromePool()

    /// Render pixels per point: half the island's size, scaled up with a light blur.
    static let resolution: CGFloat = 1.0 / 2

    var body: some View {
        ZStack {
            if render.animated {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    surface(at: ctx.date)
                }
            } else {
                surface(at: nil)
            }
            // Darker toward the edges, and black under the notch so the island still meets it.
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: size.height * 0.4,
                           endRadius: max(size.width, size.height) * 0.75)
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.16),
                                   .init(color: .clear, location: 0.34)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func surface(at date: Date?) -> some View {
        let s = IslandGeometry.expandedScale
        let originX = (IslandGeometry.canvas.width - (islandWidth ?? size.width) * s) / 2
        // Pointer in island points (the island is drawn scaled, centered at the top of the canvas).
        let pointer = model.pointer.map { CGPoint(x: ($0.x - originX) / s, y: $0.y / s) }
        return Canvas { ctx, canvasSize in
            let w = max(8, Int(canvasSize.width * Self.resolution)), h = max(8, Int(canvasSize.height * Self.resolution))
            let mouse = pointer.map { CGPoint(x: $0.x * Self.resolution, y: $0.y * Self.resolution) }
            guard let image = pool.frame(width: w, height: h, at: date, mouse: mouse) else { return }
            // Soften the upscale so the metal reads as smooth, and keep it a little dim behind the text.
            ctx.addFilter(.blur(radius: 1.2))
            ctx.opacity = 0.85
            ctx.draw(Image(decorative: image, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: canvasSize).insetBy(dx: -2, dy: -2))
        }
    }
}

/// The simulation clock, the pointer's ripple and the pixel buffer. A reference type kept in @State.
final class LiquidChromePool {
    // The "lilac" palette from the component: glow, deep, ground.
    private static let glow = (r: 0xB9 / 255.0, g: 0xA6 / 255.0, b: 0xFF / 255.0)
    private static let deep = (r: 0x2B / 255.0, g: 0x2F / 255.0, b: 0x45 / 255.0)
    private static let ground = (r: 0x0B / 255.0, g: 0x0C / 255.0, b: 0x10 / 255.0)

    private var time = 12.0
    private var last: Date?
    private var mouse = (x: 0.0, y: 0.0, lamp: 0.0)
    private var heights: [Double] = []
    private var pixels: [UInt8] = []

    func frame(width w: Int, height h: Int, at date: Date?, mouse target: CGPoint?) -> CGImage? {
        if let date {
            let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 1.0 / 30
            last = date
            time += dt
        }
        // The ripple follows the pointer with easing and fades in and out (the web version's m.x / m.l).
        if let t = target {
            if mouse.lamp < 0.01 { mouse.x = t.x; mouse.y = Double(h) - t.y }
            mouse.x += (t.x - mouse.x) * 0.12
            mouse.y += ((Double(h) - t.y) - mouse.y) * 0.12
        }
        mouse.lamp += ((target == nil ? 0 : 1) - mouse.lamp) * 0.06

        let hw = w + 1, hh = h + 1
        if heights.count != hw * hh { heights = .init(repeating: 0, count: hw * hh) }
        if pixels.count != w * h * 4 { pixels = .init(repeating: 255, count: w * h * 4) }
        let t = time * 0.05
        let res = Double(h)
        let mx = mouse.x / res, my = mouse.y / res, lamp = mouse.lamp, uTime = time

        // Heights on a (w+1) x (h+1) grid; p is in the shader's units (gl_FragCoord / uRes.y), y up.
        heights.withUnsafeMutableBufferPointer { hp in
            DispatchQueue.concurrentPerform(iterations: hh) { row in
                let py = Double(hh - 1 - row) / res
                for col in 0..<hw {
                    let px = Double(col) / res
                    var v = Self.height(px, py, t)
                    if lamp > 0.001 {
                        let d = ((px - mx) * (px - mx) + (py - my) * (py - my)).squareRoot()
                        v += lamp * 0.03 * sin(d * 34 - uTime * 5) * exp(-d * 3.5)
                    }
                    hp[row * hw + col] = v
                }
            }
        }

        let e = 1.0 / res
        heights.withUnsafeBufferPointer { hp in
            pixels.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: h) { row in
                    for col in 0..<w {
                        // Height here, one step right, one step up (rows run top to bottom, so "up" is row - 1).
                        let below = row + 1
                        let h0 = hp[below * hw + col], hx = hp[below * hw + col + 1], hy = hp[row * hw + col]
                        var nx = (h0 - hx) / e * 0.55, ny = (h0 - hy) / e * 0.55, nz = 1.0
                        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                        nx /= len; ny /= len; nz /= len
                        // reflect((0, 0, -1), n)
                        let rx = 2 * nz * nx, ry = 2 * nz * ny
                        var c = Self.room(rx, ry)
                        let fres = (1 - nz) * (1 - nz) * 0.15
                        let dark = 0.75 + 0.25 * Self.smoothstep(0.2, 0.8, h0)
                        c.r = (c.r * 0.92 * (1 - fres) + fres) * dark
                        c.g = (c.g * 0.92 * (1 - fres) + fres) * dark
                        c.b = (c.b * 0.92 * (1 - fres) + fres) * dark
                        let i = (row * w + col) * 4
                        out[i] = UInt8(max(0, min(255, c.r * 255)))
                        out[i + 1] = UInt8(max(0, min(255, c.g * 255)))
                        out[i + 2] = UInt8(max(0, min(255, c.b * 255)))
                        out[i + 3] = 255
                    }
                }
            }
        }
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: The shader, in Swift

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        n = (n ^ (n >> 13)) &* 1_274_126_177
        n ^= n >> 16
        return Double(n) / Double(UInt32.max)
    }

    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        var fx = x - ix, fy = y - iy
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        let i = Int(ix), j = Int(iy)
        let a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1)
        return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
    }

    private static func fbm(_ x: Double, _ y: Double) -> Double {
        var v = 0.0, a = 0.5, px = x, py = y
        for _ in 0..<4 {
            v += a * valueNoise(px, py)
            px = px * 2.02 + 7.3; py = py * 2.02 + 7.3
            a *= 0.5
        }
        return v
    }

    /// The folded height field: fbm warped by two fbm offsets.
    private static func height(_ x: Double, _ y: Double, _ t: Double) -> Double {
        let qx = fbm(x, y + t), qy = fbm(x + 5.2 - t, y + 1.3 - t)
        return fbm(x + 1.8 * qx + 0.3 * t, y + 1.8 * qy)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The studio the metal reflects: two coloured walls, a strip light overhead, a dark floor.
    private static func room(_ rx: Double, _ up: Double) -> (r: Double, g: Double, b: Double) {
        let s1 = smoothstep(-0.6, 0.3, up)
        var r = ground.r * 1.2 + (deep.r - ground.r * 1.2) * s1
        var g = ground.g * 1.2 + (deep.g - ground.g * 1.2) * s1
        var b = ground.b * 1.2 + (deep.b - ground.b * 1.2) * s1
        let s2 = smoothstep(0.1, 0.7, rx * 0.6 + up * 0.5) * 0.85
        r += (glow.r - r) * s2; g += (glow.g - g) * s2; b += (glow.b - b) * s2
        let strip = exp(-pow((up - 0.62) / 0.05, 2)) * 1.1
        let side = exp(-pow((rx + 0.55) / 0.04, 2)) * smoothstep(-0.2, 0.6, up) * 0.6
        return (r + strip + side, g + strip + side, b + strip + side)
    }
}
