import AppKit
import SwiftUI

/// The first AskUserQuestion question.
struct ClaudeQuestion: Equatable {
    struct Option: Equatable { let label: String; let detail: String }
    let text: String
    let options: [Option]
    let multi: Bool
    /// Number of questions in the request. More than one is answered in the app.
    let count: Int

    /// Answerable in the notch only if it all fits: one question, up to 3 lines, up to 4 options.
    var fitsNotch: Bool {
        count == 1 && (1...4).contains(options.count) && ClaudeLayout.questionLines(text) <= 3
            && options.allSatisfy { ($0.label as NSString).size(withAttributes: [.font: ClaudeLayout.optionFont]).width <= 220 }
    }
}

/// A Claude Code alert in the notch.
struct ClaudeNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// code: the detail is a command or URL, shown in monospace.
        case permission(title: String, detail: String, code: Bool)
        case question(ClaudeQuestion)
        case done(summary: String, minutes: Int?)
        case waiting
        case error(String)
    }

    let id = UUID()
    let session: String
    let project: String
    let kind: Kind
    let hostName: String?
    var answerable = false
    /// Answered from the notch. The critter reacts before the alert leaves.
    var answered: (allow: Bool, at: Date)?
    var chosen: [String]?

    /// Set when the question can be answered by clicking options; otherwise it links to the app.
    var listQuestion: ClaudeQuestion? {
        guard answerable, case .question(let q) = kind, q.fitsNotch else { return nil }
        return q
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.answerable == b.answerable && a.answered?.allow == b.answered?.allow
    }

    var priority: Int {
        switch kind {
        case .permission: 4
        case .question: 3
        case .error: 2
        case .waiting: 1
        case .done: 0
        }
    }

    /// Right ear label when no music is playing.
    var earLabel: String {
        switch kind {
        case .done: Strings.claudeDone
        case .error: Strings.claudeError
        default: project
        }
    }
    var earDot: Bool { priority >= 3 }

    /// Opens on hover. Errors stay in the ear.
    var expandable: Bool { if case .error = kind { false } else { true } }
}

enum ClaudeLayout {
    static let earWidth: CGFloat = 54
    static let earMaxWidth: CGFloat = 122
    static let earFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Ears widen to fit the project name, up to a cap.
    static func earWidth(_ notice: ClaudeNotice?) -> CGFloat {
        guard let notice else { return earWidth }
        let text = (notice.earLabel as NSString).size(withAttributes: [.font: earFont]).width
        let needed = 12 + text + (notice.earDot ? 11 : 0) + 8
        return min(earMaxWidth, max(earWidth, needed.rounded(.up)))
    }
    static let radius: CGFloat = 22
    static let earUnit: CGFloat = 2
    static let unit: CGFloat = 3

    static let questionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let optionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let questionLineHeight: CGFloat = 17

    /// Lines the question takes next to the critter.
    static func questionLines(_ text: String) -> Int {
        let width: CGFloat = 420 - 18 - 16 - 14 * 2.5 - 12 - 6
        let h = (text as NSString).boundingRect(with: CGSize(width: width, height: 400), options: [.usesLineFragmentOrigin], attributes: [.font: questionFont]).height
        return max(1, Int((h / questionFont.boundingRectForFont.height).rounded()))
    }

    // Option rows
    static let optionRow: CGFloat = 30
    static let footer: CGFloat = 26

    static func listHeight(_ q: ClaudeQuestion) -> CGFloat { listHeight(lines: questionLines(q.text), options: q.options.count) }

    static func listHeight(lines: Int, options: Int) -> CGFloat {
        let n = CGFloat(options)
        return 4 + CGFloat(lines) * questionLineHeight + 16 + 10 + n * optionRow + (n - 1) * 2 + 10 + footer + 12
    }

    /// The tallest drop the notch shows: a three-line question with four options (see fitsNotch).
    static let tallest = listHeight(lines: 3, options: 4)

    static func size(_ notice: ClaudeNotice?, notch: CGSize) -> CGSize {
        let c = notice.map(content) ?? content(kind: .waiting)
        return CGSize(width: c.width, height: notch.height + c.height)
    }

    static func content(_ notice: ClaudeNotice) -> CGSize {
        if let q = notice.listQuestion { return CGSize(width: 420, height: listHeight(q)) }
        return content(kind: notice.kind)
    }

    static func content(kind: ClaudeNotice.Kind) -> CGSize {
        switch kind {
        case .permission, .waiting: CGSize(width: 380, height: 56)
        case .question(let q): CGSize(width: 420, height: questionLines(q.text) > 1 ? 100 : 82)
        case .done: CGSize(width: 430, height: 64)
        case .error: CGSize(width: 380, height: 56)
        }
    }
}

// MARK: - Critter

struct CritterPose {
    var y = 0.0, crouch = 0.0, armL = 0.0, armR = 0.0, look = 0.0, blink = 0.0, happy = 0.0, tap = 0.0, spark = 0.0
    var visible = true
}

/// Each motion animates continuously until `active` (ms), then only blinks and glances from `idleFrom`.
/// A still critter is not redrawn.
enum CritterMotion: Equatable {
    case ask(answered: Bool?, at: Date?), done, wait, sad, happy
    case earPeek, earDone, earWait, earSad

    var active: Double {
        switch self {
        case .ask(let a, _): a == nil ? 1600 : .infinity
        case .done, .earDone: 1800
        case .wait: 8000
        case .sad: 900
        case .happy: 900
        case .earPeek: 1900
        case .earWait: 7200
        case .earSad: 1000
        }
    }

    var idleFrom: Double? {
        switch self {
        case .ask(let a, _): a == nil ? 1500 : nil
        case .wait: 8000
        case .happy: 900
        case .earPeek: 1900
        case .earWait: 7200
        case .done, .sad, .earDone, .earSad: nil
        }
    }

    func pose(_ t: Double, start: Date) -> CritterPose {
        var p = CritterPose()
        switch self {
        case .ask(let answered, let at):
            Self.drop(t, &p)
            if t > 650, t < 1450 { p.armR = max(0, sin(.pi * 4 * (t - 650) / 800)) }
            Self.idle(t - 1500, &p)
            if let answered, let at {
                let u = t - at.timeIntervalSince(start) * 1000
                p.look = 0; p.blink = 0
                if answered {
                    p.happy = 1; p.y = -3 * Self.pulse(u, 60, 380); p.crouch = Self.pulse(u, 0, 80)
                    p.armL = Self.pulse(u, 60, 380); p.armR = p.armL
                } else {
                    p.blink = 0.6; p.crouch = Self.seg(u, 0, 160); p.armR = 0
                }
            }
        case .done:
            p = Self.done(t)
        case .wait:
            Self.drop(t, &p)
            p.look = -Self.seg(t, 800, 950, Self.inOut) + 2 * Self.seg(t, 1250, 1400, Self.inOut) - Self.seg(t, 1700, 1850, Self.inOut)
            if t > 1950, t < 8000 { p.tap = 0.5 - 0.5 * cos(2 * .pi * (t - 1950) / 240) }
            if t > 2700, t < 2850 { p.blink = 1 }
            Self.idle(t - 8000, &p)
        case .sad:
            Self.drop(t, &p)
            if t > 600 { p.blink = 0.6; p.crouch = max(p.crouch, Self.seg(t, 600, 800)) }
        case .happy:
            Self.drop(t, &p)
            p.happy = 1
            Self.idle(t - 900, &p)
            p.blink = 0
        case .earDone:
            p = Self.done(t)
            if t < 520 { p.y = 9 * (1 - Self.seg(t, 0, 420, Self.back)); p.crouch = 0; p.visible = true } else { p.y *= 0.35; p.spark = 0 }
        case .earPeek, .earWait, .earSad:
            p.y = 9 * (1 - Self.seg(t, 100, 520, Self.back))
            p.look = Self.seg(t, 900, 1050, Self.inOut) - Self.seg(t, 1650, 1800, Self.inOut)
            if t > 1250, t < 1400 { p.blink = 1 }
            if self == .earWait, t > 1100, t < 7200 { p.tap = 0.5 - 0.5 * cos(2 * .pi * (t - 1100) / 240) }
            if self == .earSad, t > 700 { p.look = 0; p.blink = 0.6; p.crouch = Self.seg(t, 700, 900) }
            if self != .earSad { Self.idle(t - (self == .earWait ? 7200 : 1900), &p) }
        }
        return p
    }

    // Drops out of the notch and squashes on landing.
    private static func drop(_ t: Double, _ p: inout CritterPose, start: Double = 80) {
        p.visible = t >= start
        p.y = -11 * (1 - seg(t, start, start + 330, { $0 * $0 }))
        p.crouch = pulse(t, start + 330, start + 500)
    }

    /// After this the critter stops moving and is no longer drawn. A permission can wait for minutes.
    static let idleDuration: Double = 30000

    /// Blinks every 2.9 s and glances around now and then.
    private static func idle(_ t: Double, _ p: inout CritterPose) {
        guard t >= 0, t < idleDuration else { return }
        if t.truncatingRemainder(dividingBy: 2900) < 150 { p.blink = 1 }
        let c = t.truncatingRemainder(dividingBy: 6200)
        p.look = -seg(c, 1800, 1950, inOut) + seg(c, 2600, 2750, inOut) + seg(c, 3300, 3450, inOut) - seg(c, 4100, 4250, inOut)
    }

    /// Two happy jumps with sparks.
    private static func done(_ t: Double) -> CritterPose {
        var p = CritterPose()
        drop(t, &p)
        p.happy = seg(t, 560, 600, { $0 })
        p.crouch = max(p.crouch, pulse(t, 600, 740), pulse(t, 1120, 1260), pulse(t, 1560, 1680))
        if t > 740, t < 1120 { let j = sin(.pi * (t - 740) / 380); p.y = -5 * j; p.armL = min(1, j * 1.6); p.armR = p.armL }
        if t > 1260, t < 1560 { let j = sin(.pi * (t - 1260) / 300); p.y = -2.5 * j; p.armL = min(1, j * 1.6); p.armR = p.armL }
        p.spark = seg(t, 1120, 1720, { $0 })
        return p
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func seg(_ t: Double, _ a: Double, _ b: Double, _ ease: (Double) -> Double = { 1 - pow(1 - $0, 3) }) -> Double {
        ease(clamp((t - a) / (b - a)))
    }
    static func pulse(_ t: Double, _ a: Double, _ b: Double) -> Double { t <= a || t >= b ? 0 : sin(.pi * (t - a) / (b - a)) }
    static let inOut: (Double) -> Double = { $0 < 0.5 ? 4 * $0 * $0 * $0 : 1 - pow(-2 * $0 + 2, 3) / 2 }
    static let back: (Double) -> Double = { t in let c1 = 1.7, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
}

/// Pixel critter: 14 × 8 body, two eyes, arms and four legs.
enum CritterDrawing {
    /// Frames drawn, for tests.
    nonisolated(unsafe) static var frames = 0
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let body = ["...BBBBBBBB...", "..BBBBBBBBBB..", "..BBBBBBBBBB..", "..BBBBBBBBBB..", "..BBBBBBBBBB..", "...BBBBBBBB..."]
    private static let legs: [Double] = [3, 5, 8, 10]
    private static let eyes: [Double] = [4, 9]

    /// 22 × 20 canvas with the body at (4, 10), leaving room to jump.
    static func draw(_ p: CritterPose, in gc: GraphicsContext, unit u: CGFloat) {
        guard p.visible else { return }
        let c = (CritterMotion.clamp(p.crouch)).rounded()
        let dy = p.y.rounded() + c
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, dy: Double) -> Path {
            Path(CGRect(x: (x + 4) * u, y: (y + 10 + dy) * u, width: w * u, height: h * u))
        }
        var shape = Path()
        for (y, row) in body.enumerated() {
            for (x, ch) in row.enumerated() where ch == "B" { shape.addPath(rect(Double(x), Double(y), 1, 1, dy: dy)) }
        }
        for (i, lift) in [p.armL, p.armR].enumerated() {
            shape.addPath(rect(i == 0 ? 0 : 12, 3 - (CritterMotion.clamp(lift) * 2).rounded(), 2, 1, dy: dy))
        }
        for (i, x) in legs.enumerated() {
            let lift = i == 3 ? CritterMotion.clamp(p.tap).rounded() : 0
            let h = max(0, 2 - c - lift)
            if h > 0 { shape.addPath(rect(x, 6, 1, h, dy: dy)) }
        }
        gc.fill(shape, with: .color(clay))

        var ink = Path()
        let look = p.look.rounded()
        for ex in eyes {
            let x = ex + look
            if p.happy > 0.5 {
                // Happy: "^" eyes.
                ink.addPath(rect(x - 1, 3, 1, 1, dy: dy)); ink.addPath(rect(x, 2, 1, 1, dy: dy)); ink.addPath(rect(x + 1, 3, 1, 1, dy: dy))
            } else if p.blink > 0.4 {
                ink.addPath(rect(x, 3, 1, 1, dy: dy))
            } else {
                ink.addPath(rect(x, 2, 1, 2, dy: dy))
            }
        }
        gc.fill(ink, with: .color(.black))

        // Sparks on landing.
        let s = p.spark
        guard s > 0, s < 1, sin(.pi * s) > 0.3 else { return }
        let spread = 1 + 1.1 * s
        for (i, (sx, sy)) in [(-1.5, -1.5), (14.5, -2.0), (-2.5, 3.0), (15.5, 2.5)].enumerated() {
            let cx = (7 + (sx - 7) * spread).rounded(), cy = (3 + (sy - 3) * spread + p.y).rounded()
            gc.fill(rect(cx - 0.5, cy - 0.5, 1, 1, dy: 0), with: .color(i % 2 == 0 ? Color(red: 0.95, green: 0.63, blue: 0.49) : .white))
        }
    }
}

/// Redraw every 90 ms while moving (sprite-like steps), then only on blinks and glances.
struct CritterSchedule: TimelineSchedule {
    let start: Date
    let active: Double
    let idleFrom: Double?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Never return a past date: SwiftUI treats it as overdue and asks again every frame.
        var last: Double? = nil
        let start = start, now = startDate.timeIntervalSince(start) * 1000
        var done = false
        return AnyIterator {
            guard !done else { return nil }
            guard let r = last else { last = now; return startDate }
            guard let next = nextChange(after: r) else {
                // End with a far date instead of ending the sequence, which SwiftUI would re-request every frame.
                done = true
                return .distantFuture
            }
            last = next
            return start.addingTimeInterval(next / 1000)
        }
    }

    func nextChange(after r: Double) -> Double? {
        if r < active {
            let tick = ((r / 90).rounded(.down) + 1) * 90
            if tick < active { return tick }
            if active.isFinite { return active }
            return nil
        }
        guard let idle = idleFrom else { return nil }
        let end = idle + CritterMotion.idleDuration
        guard r < end else { return nil }
        return min(idle + Self.nextKey(after: r - idle), end)
    }

    /// Idle pose changes, 1 ms after each edge.
    private static func nextKey(after r: Double) -> Double {
        var best = Double.infinity
        for (cycle, keys) in [(2900.0, [1.0, 151.0]), (6200.0, [1876.0, 2676.0, 3376.0, 4176.0])] {
            let base = (r / cycle).rounded(.down) * cycle
            for k in keys + keys.map({ $0 + cycle }) where base + k > r { best = min(best, base + k) }
        }
        return best
    }
}

struct CritterView: View {
    let unit: CGFloat
    let motion: CritterMotion
    // Built without Xcode, so no @State macro: State is used directly.
    private let startState = State(initialValue: Date())

    var body: some View {
        let start = startState.wrappedValue
        TimelineView(CritterSchedule(start: start, active: motion.active, idleFrom: motion.idleFrom)) { ctx in
            let raw = SnapshotRenderer.isActive ? SnapshotRenderer.faceTime : ctx.date.timeIntervalSince(start) * 1000
            let ms = raw < motion.active ? (raw / 90).rounded(.down) * 90 : raw
            Canvas { gc, _ in
                CritterDrawing.frames += 1
                CritterDrawing.draw(motion.pose(ms, start: start), in: gc, unit: unit)
            }
        }
        .frame(width: 22 * unit, height: 20 * unit)
        .offset(x: -4 * unit, y: -10 * unit)
        .frame(width: 14 * unit, height: 8 * unit, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Content

/// Critter on the left; the label on the right when no music is playing.
struct ClaudeEarContent: View {
    let notice: ClaudeNotice
    let showsLabel: Bool
    let notchHeight: CGFloat

    private var isError: Bool { if case .error = notice.kind { true } else { false } }

    private var motion: CritterMotion {
        switch notice.kind {
        case .done: .earDone
        case .waiting: .earWait
        case .error: .earSad
        case .permission, .question: .earPeek
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            CritterView(unit: ClaudeLayout.earUnit, motion: motion)
                .id(notice.id)
            Spacer(minLength: 0)
            if showsLabel {
                HStack(spacing: 5) {
                    Text(notice.earLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isError ? Color(red: 1, green: 0.54, blue: 0.5) : .white.opacity(0.62))
                    if notice.earDot { Circle().fill(CritterDrawing.clay).frame(width: 6, height: 6) }
                }
                .font(Font(ClaudeLayout.earFont))
                .frame(maxWidth: ClaudeLayout.earWidth(notice) - 18, alignment: .trailing)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: notchHeight)
    }
}

struct ClaudeOpenContent: View {
    let notice: ClaudeNotice
    let answer: (Bool) -> Void
    let choose: ([String]) -> Void
    let focus: () -> Void

    var body: some View {
        content
            // The whole drop goes to Claude's window; the ✕ / ✓ buttons take precedence.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: focus)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch notice.kind {
            case .permission(let title, let detail, let code):
                row {
                    CritterView(unit: ClaudeLayout.unit, motion: .ask(answered: notice.answered?.allow, at: notice.answered?.at))
                    texts(Text(title), Text("\(notice.project) · ") + Text(detail).font(code ? .system(size: 11.5, design: .monospaced) : .system(size: 12)))
                    if let answered = notice.answered {
                        Label(answered.allow ? Strings.claudeAllowed : Strings.claudeDenied,
                              systemImage: answered.allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize()
                            .transition(.blurFade)
                    } else if notice.answerable {
                        RoundAnswer(allow: false) { answer(false) }
                        RoundAnswer(allow: true) { answer(true) }
                    } else {
                        chevron
                    }
                }
            case .question(let question) where notice.listQuestion != nil:
                QuestionList(notice: notice, question: question, choose: choose, focus: focus)
            case .question(let question):
                let text = question.text, options = question.options.map(\.label)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        CritterView(unit: 2.5, motion: .wait)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                            Text("\(notice.project) · \(Strings.claudeAsks)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        .padding(.leading, 6)
                    }
                    HStack(spacing: 6) {
                        // Options that fit whole; the rest as "+2".
                        ViewThatFits(in: .horizontal) {
                            ForEach(Array(stride(from: min(options.count, 4), through: 0, by: -1)), id: \.self) { n in
                                HStack(spacing: 6) {
                                    ForEach(Array(options.prefix(n).enumerated()), id: \.offset) { _, option in chip(option) }
                                    if options.count > n { chip("+\(options.count - n)", dim: true) }
                                }
                                .fixedSize()
                            }
                        }
                        Spacer(minLength: 8)
                        Text(String(format: Strings.claudeAnswerIn, notice.hostName ?? "Claude"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.leading, 18).padding(.trailing, 16).padding(.top, 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(perform: focus)
            case .done(let summary, let minutes):
                row {
                    CritterView(unit: ClaudeLayout.unit, motion: .happy)
                    let meta = [notice.project, minutes.map { String(format: Strings.claudeMinutes, $0) }].compactMap { $0 }.joined(separator: " · ")
                    VStack(alignment: .leading, spacing: 1) {
                        (Text(Strings.claudeDone) + Text("  \(meta)").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.5)))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(Self.meaningful(summary) ? summary : Strings.claudeDoneDetail)
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focus)
                }
            case .waiting:
                row {
                    CritterView(unit: ClaudeLayout.unit, motion: .wait)
                    texts(Text(Strings.claudeWaiting) + Text("  \(notice.project)").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.5)),
                          Text(Strings.claudeWaitingDetail))
                    chevron
                }
            case .error(let message):
                row {
                    CritterView(unit: ClaudeLayout.unit, motion: .sad)
                    texts(Text(Strings.claudeError), Text(message))
                }
            }
        }
    }

    /// A summary that says something, not just "Done."
    static func meaningful(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 12
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(maxHeight: .infinity)
    }

    private func texts(_ title: Text, _ subtitle: Text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            subtitle.font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
    }

    private func chip(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(dim ? 0.55 : 0.88))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.2)))
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .onTapGesture(perform: focus)
    }
}

/// Question with one option per row. Multi-select questions use checkmarks and a Send button.
private struct QuestionList: View {
    let notice: ClaudeNotice
    let question: ClaudeQuestion
    let choose: ([String]) -> Void
    let focus: () -> Void
    // Built without Xcode, so no @State macro: State is used directly.
    private let selection = State(initialValue: Set<Int>())
    private let hovered = State<Int?>(initialValue: nil)

    private var answered: Bool { notice.answered != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CritterView(unit: 2.5, motion: answered ? .happy : .wait)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.text)
                        .font(Font(ClaudeLayout.questionFont)).foregroundStyle(.white)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: focus)
            }
            VStack(spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in row(i, option) }
            }
            .padding(.horizontal, -8)
            HStack {
                Text(String(format: Strings.claudeOtherAnswerIn, notice.hostName ?? "Claude"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focus)
                Spacer(minLength: 8)
                if question.multi {
                    Button {
                        choose(selection.wrappedValue.sorted().map { question.options[$0].label })
                    } label: {
                        Text(Strings.claudeSend)
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: ClaudeLayout.footer)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(PressScale())
                    .disabled(selection.wrappedValue.isEmpty || answered)
                    .opacity(selection.wrappedValue.isEmpty && !answered ? 0.3 : 1)
                }
            }
            .frame(height: ClaudeLayout.footer)
        }
        .padding(.leading, 18).padding(.trailing, 16).padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        if let chosen = notice.chosen { return String(format: Strings.claudeAnswered, chosen.joined(separator: ", ")) }
        return "\(notice.project) · \(Strings.claudeAsks)"
    }

    private func row(_ i: Int, _ option: ClaudeQuestion.Option) -> some View {
        let chosen = notice.chosen?.contains(option.label) == true
        let selected = selection.wrappedValue.contains(i)
        let fill: Color = chosen ? .white : .white.opacity(selected ? 0.16 : hovered.wrappedValue == i && !answered ? 0.1 : 0)
        return Button {
            guard !answered else { return }
            if question.multi {
                if selected { selection.wrappedValue.remove(i) } else { selection.wrappedValue.insert(i) }
            } else {
                choose([option.label])
            }
        } label: {
            HStack(spacing: 10) {
                if question.multi { CheckCircle(on: selected || chosen, onWhite: chosen) }
                Text(option.label).font(Font(ClaudeLayout.optionFont)).lineLimit(1).fixedSize()
                Text(option.detail).font(.system(size: 12)).opacity(chosen ? 0.55 : 0.5).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(chosen ? Color.black : .white)
            .padding(.horizontal, 10)
            .frame(height: ClaudeLayout.optionRow)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .contentShape(Rectangle())
            .animation(.smooth(duration: 0.15), value: fill)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .onHover { inside in
            if inside { hovered.wrappedValue = i } else if hovered.wrappedValue == i { hovered.wrappedValue = nil }
        }
    }
}

private struct CheckCircle: View {
    let on: Bool
    /// Black check on the white row of a chosen option.
    let onWhite: Bool

    var body: some View {
        ZStack {
            if on {
                Circle().fill(onWhite ? Color.black : .white)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(onWhite ? Color.white : .black)
            } else {
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
            }
        }
        .frame(width: 15, height: 15)
    }
}

private struct RoundAnswer: View {
    let allow: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: allow ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(allow ? .black : .white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(allow ? Color.white : Color.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(allow ? Strings.claudeAllow : Strings.claudeDeny)
    }
}

private struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.88
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}
