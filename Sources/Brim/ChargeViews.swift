import SwiftUI

/// Charging alert: the Face ID style face with status and percentage.
struct ChargeEvent: Identifiable, Equatable {
    enum Kind { case plugged, charged, unplugged, full, low }
    let id = UUID()
    let kind: Kind
    let percent: Int
}

/// A click on the notch with nothing playing. annoyed: third click in a row.
struct BoopEvent: Identifiable, Equatable {
    let id = UUID()
    let annoyed: Bool
}

struct BoopContent: View {
    let event: BoopEvent

    var body: some View {
        FaceAnimation(timeline: { FaceDrawing.boopParams(at: $0, annoyed: event.annoyed) })
            .frame(width: 34, height: 34)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ChargeContent: View {
    let event: ChargeEvent

    private var title: String {
        switch event.kind {
        case .plugged: Strings.charging
        case .charged, .full: Strings.charged
        case .unplugged: Strings.onBattery
        case .low: Strings.lowBattery
        }
    }

    var body: some View {
        let green = event.kind != .unplugged && event.kind != .low
        let tint: Color = green ? Color(nsColor: .systemGreen)
            : event.kind == .low ? Color(nsColor: event.percent <= 10 ? .systemRed : .systemOrange) : .white
        HStack(spacing: 12) {
            FaceAnimation(timeline: { FaceDrawing.params(at: $0, kind: event.kind) })
                .frame(width: 34, height: 34)
                .frame(width: 40, height: 40)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                if green { Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)) }
                Text(Strings.percent(event.percent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
        }
        .padding(.leading, 18)
        .padding(.trailing, 20)
        .padding(.bottom, 6)
    }
}

/// Draws the face frame by frame while the alert is up (about 3 s), then the view goes away.
struct FaceAnimation: View {
    /// Face parameters at each moment, in ms since it appeared.
    let timeline: (Double) -> FaceDrawing.Params
    // Built without Xcode, so no @State macro: State is used directly.
    private let startState = State(initialValue: Date())

    var body: some View {
        TimelineView(.animation) { ctx in
            let ms = SnapshotRenderer.isActive ? SnapshotRenderer.faceTime : ctx.date.timeIntervalSince(startState.wrappedValue) * 1000
            Canvas { gc, size in FaceDrawing.draw(timeline(ms), in: gc, size: size) }
        }
    }
}

/// Animation timelines in milliseconds.
enum FaceDrawing {
    struct Params {
        var intro = 0.0, eyes = 0.0, nose = 0.0, mouth = 0.0, smile = 0.0, look = 0.0, blink = 0.0
        var happy = 0.0, big = 0.0, jump = 0.0, squash = 0.0, pulse = 1.0, green = 0.0
        /// Boop: wink, surprise ("O O"), annoyed ("> <") and shake.
        var wink = 0.0, surprise = 0.0, annoyed = 0.0, shake = 0.0
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func back(_ t: Double) -> Double { let c1 = 1.7, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
    private static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private static func seg(_ t: Double, _ a: Double, _ b: Double, _ f: (Double) -> Double = out) -> Double { f(clamp((t - a) / (b - a))) }
    private static func pulse(_ t: Double, _ a: Double, _ b: Double) -> Double { sin(.pi * seg(t, a, b, { $0 })) }

    static func params(at t: Double, kind: ChargeEvent.Kind) -> Params {
        var p = Params()
        p.intro = seg(t, 0, 520, back)
        p.eyes = seg(t, 260, 480, back)
        p.nose = seg(t, 380, 560, back)
        p.mouth = seg(t, 420, 640)
        switch kind {
        case .plugged, .charged:
            p.smile = seg(t, 600, 900, back)
            p.blink = pulse(t, 1080, 1260)
            p.green = kind == .charged ? seg(t, 850, 1100) : 0
        case .unplugged:
            // Starts smiling, then turns serious and looks down.
            p.smile = 1 - seg(t, 800, 1150, inOut)
            p.look = seg(t, 820, 1150, inOut)
        case .low:
            // Sad: mouth curves down, looks down, slow blink.
            p.smile = -0.8 * seg(t, 650, 1000, inOut)
            p.look = 0.9 * seg(t, 700, 1050, inOut)
            p.blink = pulse(t, 1300, 1700)
        case .full:
            // Charge limit reached: green corners, "^ ^" eyes, a jump with a squash, and a pulse.
            p.smile = seg(t, 600, 900, back)
            p.green = seg(t, 850, 1100)
            p.happy = clamp(seg(t, 950, 1100, back))
            p.big = seg(t, 950, 1150, back)
            p.jump = 7 * (t < 1250 ? seg(t, 1000, 1250) : 1 - seg(t, 1250, 1450, { $0 * $0 }))
            p.squash = pulse(t, 1450, 1650)
            p.pulse = 1 + 0.12 * pulse(t, 1450, 1750)
        }
        return p
    }

    /// Startled, then relaxes, smiles and winks.
    /// Three clicks in a row: annoyed.
    static func boopParams(at t: Double, annoyed: Bool) -> Params {
        var p = Params()
        p.eyes = 1; p.nose = 1; p.mouth = 1
        if annoyed {
            p.intro = 1
            p.annoyed = clamp(seg(t, 0, 160, back) - seg(t, 1250, 1450))
            p.shake = 1.6 * sin(t / 22) * (1 - seg(t, 150, 800, { $0 }))
        } else {
            p.intro = seg(t, 0, 300, back)
            p.surprise = clamp(seg(t, 120, 260, back) - seg(t, 750, 950, inOut))
            p.shake = t > 150 && t < 450 ? 1.2 * sin(t / 18) : 0
            p.smile = seg(t, 900, 1150, back)
            p.wink = clamp(seg(t, 1150, 1300, back) - seg(t, 1600, 1750))
        }
        return p
    }

    /// 40×40 canvas scaled to the view.
    static func draw(_ p: Params, in gc: GraphicsContext, size: CGSize) {
        var gc = gc
        let s = min(size.width, size.height) / 40
        gc.scaleBy(x: s, y: s)
        // Jump and squash, floor at y = 38.
        gc.translateBy(x: 20, y: 38 - p.jump)
        gc.scaleBy(x: 1 + p.squash * 0.08, y: 1 - p.squash * 0.12)
        gc.translateBy(x: -20 + p.shake, y: -38)

        let green = Color(nsColor: .systemGreen)
        let frameColor = p.green > 0.5 ? green : .white
        let style = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)

        // Face ID corners spin in from outside and close.
        let k = (1 + (1 - p.intro) * 0.45) * p.pulse
        let rot = Angle.degrees((1 - p.intro) * 40)
        var corners = gc
        corners.opacity = clamp(p.intro * 1.4)
        corners.translateBy(x: 20, y: 20)
        corners.rotate(by: rot)
        corners.scaleBy(x: k, y: k)
        corners.translateBy(x: -20, y: -20)
        for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
            var path = Path()
            path.move(to: CGPoint(x: 20 - sx * 17, y: 20 - sy * 9))
            path.addLine(to: CGPoint(x: 20 - sx * 17, y: 20 - sy * 11))
            path.addQuadCurve(to: CGPoint(x: 20 - sx * 11, y: 20 - sy * 17), control: CGPoint(x: 20 - sx * 17, y: 20 - sy * 17))
            path.addLine(to: CGPoint(x: 20 - sx * 9, y: 20 - sy * 17))
            corners.stroke(path, with: .color(p.green > 0 && p.green < 1 ? .white.opacity(1 - p.green) : frameColor), style: style)
            if p.green > 0 && p.green < 1 { corners.stroke(path, with: .color(green.opacity(p.green)), style: style) }
        }

        // Eyes: blinking vertical lines that morph into "^" (happy, wink), "O" (surprised) or "> <" (annoyed).
        let y = 15.5 + p.look
        let normal = 1 - max(p.surprise, p.annoyed)
        let thin = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        for (i, x) in [14.5, 25.5].enumerated() {
            let arcAmount = max(p.happy, i == 1 ? p.wink : 0)
            let h = 5 * p.eyes * (1 - 0.88 * p.blink)
            if p.eyes > 0 && arcAmount < 1 && normal > 0 {
                var eye = Path()
                eye.move(to: CGPoint(x: x, y: y - h / 2))
                eye.addLine(to: CGPoint(x: x, y: y + h / 2 + 0.01))
                gc.stroke(eye, with: .color(.white.opacity((1 - arcAmount) * normal)), style: style)
            }
            if arcAmount > 0 {
                var arc = Path()
                arc.move(to: CGPoint(x: x - 2.8, y: y + 1.2))
                arc.addQuadCurve(to: CGPoint(x: x + 2.8, y: y + 1.2), control: CGPoint(x: x, y: y - 3.4))
                gc.stroke(arc, with: .color(.white.opacity(arcAmount * normal)), style: style)
            }
            if p.surprise > 0 {
                let rx = 1.4 + 1.2 * p.surprise, ry = 1.6 + 1.6 * p.surprise
                gc.stroke(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)),
                          with: .color(.white.opacity(clamp(p.surprise))), style: thin)
            }
            if p.annoyed > 0 {
                let d: CGFloat = i == 1 ? -1 : 1
                var chevron = Path()
                chevron.move(to: CGPoint(x: x - d * 2.4, y: y - 2.6))
                chevron.addLine(to: CGPoint(x: x + d * 2.2, y: y))
                chevron.addLine(to: CGPoint(x: x - d * 2.4, y: y + 2.6))
                gc.stroke(chevron, with: .color(.white.opacity(clamp(p.annoyed))), style: style)
            }
        }

        // Hook nose. Hidden with "^" eyes so the shapes don't collide.
        let n = p.nose * (1 - max(p.happy, p.wink)) * normal
        if n > 0.02 {
            var nose = Path()
            nose.move(to: CGPoint(x: 20.5, y: 14 + p.look))
            nose.addLine(to: CGPoint(x: 20.5, y: 14 + p.look + 6.5 * n))
            nose.addLine(to: CGPoint(x: 20.5 - 2 * n, y: 14 + p.look + 6.5 * n))
            gc.stroke(nose, with: .color(.white), style: style)
        }

        // Mouth: a smile that flattens when unplugging, a zigzag when annoyed, an "o" when surprised.
        let my = 25.5 + p.look * 0.5
        if p.mouth > 0.02 && p.annoyed > 0.5 {
            let w = 6 * p.mouth, step = w / 2.5
            var zig = Path()
            zig.move(to: CGPoint(x: 20 - w, y: my + 1))
            for k in 1...5 { zig.addLine(to: CGPoint(x: 20 - w + step * Double(k), y: my + (k % 2 == 1 ? -0.6 : 1))) }
            gc.stroke(zig, with: .color(.white.opacity(clamp(p.annoyed))), style: style)
        } else if p.mouth > 0.02 && p.surprise < 1 {
            let w = (6 + 1.5 * p.big) * p.mouth
            var mouth = Path()
            mouth.move(to: CGPoint(x: 20 - w, y: my))
            mouth.addQuadCurve(to: CGPoint(x: 20 + w, y: my), control: CGPoint(x: 20, y: my + (4.2 + 2.2 * p.big) * p.smile))
            gc.stroke(mouth, with: .color(.white.opacity(1 - p.surprise)), style: style)
        }
        if p.surprise > 0 {
            let rx = 1.6 + 1.2 * p.surprise, ry = 1.8 + 1.6 * p.surprise
            gc.stroke(Path(ellipseIn: CGRect(x: 20 - rx, y: my + 1 - ry, width: rx * 2, height: ry * 2)),
                      with: .color(.white.opacity(clamp(p.surprise))), style: thin)
        }
    }
}
