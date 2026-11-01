import SwiftUI

/// Codex's character: a lavender pompom with oval eyes, drawn smooth instead of in pixels.
/// It takes the same poses as Claude's critter, on the same 22 × 20 canvas, standing where the
/// critter's feet are. The fuzzy edge trembles only while frames are drawn, so it is still at rest.
enum PomponDrawing {
    static let lavender = Color(red: 143 / 255, green: 157 / 255, blue: 1)
    private static let light = Color(red: 168 / 255, green: 179 / 255, blue: 1)
    private static let shade = Color(red: 100 / 255, green: 110 / 255, blue: 179 / 255)
    private static let ink = Color(red: 23 / 255, green: 23 / 255, blue: 28 / 255)

    /// Radius in canvas units: about 11 units wide, a bit narrower than the critter's 14.
    private static let radius = 5.6
    /// Floor line, chosen so the pompom is centered where the critter's body is.
    private static let floor = 18.6

    /// A soft-cornered oval (superellipse, exponent 2.4), scaled so its wider side is 2 and
    /// standing on y = 0. Width 2, height about 1.67.
    private static let outline: [CGPoint] = {
        let n = 96, e = 2.0 / 2.4
        let raw = (0..<n).map { i -> CGPoint in
            let a = Double(i) / Double(n) * 2 * .pi, c = cos(a), s = sin(a)
            return CGPoint(x: 1.08 * copysign(pow(abs(c), e), c), y: 0.9 * copysign(pow(abs(s), e), s))
        }
        let k = 2 / 2.16
        return raw.map { CGPoint(x: $0.x * k, y: ($0.y - 0.9) * k) }
    }()
    private static let height = 1.8 * 2 / 2.16

    static func draw(_ p: CritterPose, at ms: Double, in gc: GraphicsContext, unit u: CGFloat) {
        guard p.visible else { return }
        let r = radius * u, h = height * r, w = 2 * r
        // Squash on landing and when crouching, stretch with raised "arms" (jumping).
        let sq = 0.13 * CritterMotion.clamp(p.crouch) + 0.03 * CritterMotion.clamp(p.tap) - 0.08 * max(p.armL, p.armR)

        var g = gc
        g.translateBy(x: 11 * u, y: (floor + p.y) * u)
        g.scaleBy(x: 1 + sq, y: 1 - sq)

        // Fuzzy edge: the radius from the middle wobbles a little all around.
        let cy = -h / 2
        var body = Path()
        for (i, pt) in outline.enumerated() {
            let x = pt.x * r, y = pt.y * r
            let a = atan2(y - cy, x)
            let n = 1 + 0.035 * sin(a * 23 + ms / 260) + 0.03 * sin(a * 41 - ms / 170)
            let q = CGPoint(x: x * n, y: cy + (y - cy) * n)
            if i == 0 { body.move(to: q) } else { body.addLine(to: q) }
        }
        body.closeSubpath()

        // Matte felt: light from the top left, darker toward the bottom right.
        g.fill(body, with: .radialGradient(Gradient(stops: [.init(color: light, location: 0), .init(color: lavender, location: 0.5), .init(color: shade, location: 1)]),
                                          center: CGPoint(x: -w * 0.13, y: cy - h * 0.18), startRadius: 0, endRadius: max(w, h) * 0.85))
        // Light bouncing off the floor along the bottom edge.
        g.fill(body, with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(0.1), location: 0.15),
                                                            .init(color: .white.opacity(0), location: 1)]),
                                          startPoint: .zero, endPoint: CGPoint(x: 0, y: -h * 0.35)))

        eyes(p, in: g, r: r, h: h)

        // Faint sheen, top left.
        var sheen = g
        sheen.translateBy(x: -w * 0.24, y: -h * 0.76)
        sheen.rotate(by: .radians(-0.55))
        sheen.scaleBy(x: 1, y: 0.6)
        sheen.fill(Path(ellipseIn: CGRect(x: -0.2 * r, y: -0.2 * r, width: 0.4 * r, height: 0.4 * r)),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]), center: .zero, startRadius: 0, endRadius: 0.2 * r))

        sparks(p, in: gc, u: u, r: r, h: h)
    }

    private static func eyes(_ p: CritterPose, in g: GraphicsContext, r: CGFloat, h: CGFloat) {
        let y = -h * 0.52, dx = 0.32 * r, lx = p.look * 0.09 * r
        let line = StrokeStyle(lineWidth: max(0.9, 0.085 * r), lineCap: .round)
        for side in [-1.0, 1.0] {
            let x = side * dx + lx
            if p.happy > 0.5 {
                // "^" eyes
                let k = 0.13 * r
                var arc = Path()
                arc.move(to: CGPoint(x: x - k, y: y + k * 0.45))
                arc.addQuadCurve(to: CGPoint(x: x + k, y: y + k * 0.45), control: CGPoint(x: x, y: y - k * 1.05))
                g.stroke(arc, with: .color(ink), style: line)
            } else if p.blink >= 0.9 {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 0.09 * r, y: y + 0.04 * r))
                lid.addLine(to: CGPoint(x: x + 0.09 * r, y: y + 0.04 * r))
                g.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(0.8, 0.075 * r), lineCap: .round))
            } else if p.blink > 0.4 {
                // Sad: lower, flatter eyes with worried brows.
                let ew = 0.1 * r, eh = 0.155 * r * 0.7, yy = y + 0.05 * r
                g.fill(Path(ellipseIn: CGRect(x: x - ew, y: yy - eh, width: 2 * ew, height: 2 * eh)), with: .color(ink))
                var brow = Path()
                brow.move(to: CGPoint(x: x - side * 0.11 * r, y: yy - eh - 0.19 * r))
                brow.addLine(to: CGPoint(x: x + side * 0.08 * r, y: yy - eh - 0.1 * r))
                g.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: max(0.7, 0.05 * r), lineCap: .round))
            } else {
                let ew = 0.1 * r, eh = 0.155 * r
                g.fill(Path(ellipseIn: CGRect(x: x - ew, y: y - eh, width: 2 * ew, height: 2 * eh)), with: .color(ink))
                // The glint only reads when the pompom is big.
                if r >= 20 {
                    g.fill(Path(ellipseIn: CGRect(x: x - ew * 0.3 - ew * 0.32, y: y - eh * 0.4 - ew * 0.32, width: ew * 0.64, height: ew * 0.64)),
                           with: .color(.white.opacity(0.9)))
                }
            }
        }
    }

    /// Four-point sparkles that spread out after the landing.
    private static func sparks(_ p: CritterPose, in gc: GraphicsContext, u: CGFloat, r: CGFloat, h: CGFloat) {
        let s = p.spark
        guard s > 0, s < 1 else { return }
        let alpha = sin(.pi * s), d = r * (1 + 0.6 * s)
        let cx = 11 * u, cy = (floor + p.y) * u - h * 0.55
        for (i, (ax, ay)) in [(-1.15, -1.2), (1.2, -1.1), (-1.35, -0.35), (1.4, -0.4)].enumerated() {
            let x = cx + ax * d * 0.85, y = cy + ay * d * 0.55, k = r * (i % 2 == 1 ? 0.1 : 0.13)
            var star = Path()
            star.move(to: CGPoint(x: x, y: y - k))
            star.addQuadCurve(to: CGPoint(x: x + k, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y + k), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x - k, y: y), control: CGPoint(x: x, y: y))
            star.addQuadCurve(to: CGPoint(x: x, y: y - k), control: CGPoint(x: x, y: y))
            gc.fill(star, with: .color(.white.opacity(alpha)))
        }
    }
}
