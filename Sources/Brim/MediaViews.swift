import AppKit
import SwiftUI
import QuartzCore

/// Player layer. Artwork and equalizer are single views that change size and position with the mode,
/// so they travel from the ears into the open player.
struct MediaLayer: View {
    let nowPlaying: NowPlaying
    let mode: IslandMode
    let notch: CGSize
    /// A Claude alert takes the left ear: hide the artwork, keep the equalizer.
    var hideArt = false
    let perform: (MediaCommand) -> Void

    private let s = IslandLayout.scale

    var body: some View {
        let expanded = mode == .media
        let visible = mode == .compact || mode == .media

        let artSize: CGFloat = expanded ? 100 * s : visible ? 20 * s : 10
        let artX: CGFloat = expanded ? 18 * s : visible ? 11 * s : 24
        let artY: CGFloat = expanded ? notch.height + 8 * s : (notch.height - artSize) / 2
        let artRadius: CGFloat = expanded ? 17 * s : visible ? 5 : 3

        let eqHeight: CGFloat = 13
        let eqInset: CGFloat = expanded ? 24 * s : 12 * s
        let eqY: CGFloat = expanded ? notch.height + 24 * s : (notch.height - eqHeight) / 2

        ZStack(alignment: .topLeading) {
            if expanded {
                ExpandedPlayer(nowPlaying: nowPlaying, notch: notch, perform: perform)
                    .frame(width: IslandLayout.mediaWidth, height: IslandLayout.mediaSize(notch: notch).height, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .blurFade.animation(.snappy),
                        removal: .blurFade.animation(.smooth(duration: 0.22))
                    ))
            }

            ArtworkView(nowPlaying: nowPlaying)
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))
                .onTapGesture { if expanded { perform(.openApp) } }
                .scaleEffect(hideArt ? 0.6 : 1)
                .offset(x: artX, y: artY + (hideArt ? 8 : 0))
                .opacity(visible && !hideArt ? 1 : 0)

            // Only animates while visible.
            EqualizerView(playing: nowPlaying.playing && visible, color: NSColor(nowPlaying.accent))
                .frame(width: 18, height: eqHeight)
                .scaleEffect(expanded ? 1.4 : visible ? 1 : 0.6)
                .opacity(visible ? 1 : 0)
                .offset(x: -eqInset, y: eqY)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ExpandedPlayer: View {
    let nowPlaying: NowPlaying
    let notch: CGSize
    let perform: (MediaCommand) -> Void

    private let s = IslandLayout.scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Never wider than the ear, or it would run under the physical notch.
                SourceLabel(name: nowPlaying.appName ?? Strings.nowPlaying, accent: nowPlaying.accent)
                    .frame(maxWidth: (IslandLayout.mediaWidth - notch.width) / 2 - 20 * s - 8, alignment: .leading)
                Spacer()
                IslandButton(symbol: "airplay.audio", size: 13, diameter: 24, dimmed: true) { AudioOutputs.showMenu() }
                    .accessibilityLabel(Strings.audioOutput)
            }
            .padding(.leading, 20 * s)
            .padding(.trailing, 10 * s)
            .frame(height: notch.height)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    SwapText(text: nowPlaying.title, font: .system(size: 13.5, weight: .semibold), color: .white)
                    SwapText(text: nowPlaying.artist, font: .system(size: 12), color: .white.opacity(0.55))
                }
                .padding(.trailing, 34 * s)
                .frame(height: 36, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { perform(.openApp) }

                if nowPlaying.duration > 0 {
                    Scrubber(nowPlaying: nowPlaying) { perform(.seek($0)) }
                        .frame(height: 14)
                        .padding(.top, 5)
                } else {
                    Spacer().frame(height: 19)
                }

                HStack(spacing: 14) {
                    IslandButton(symbol: "backward.fill", size: 16) { perform(.previous) }
                        .accessibilityLabel(Strings.previous)
                    IslandButton(symbol: nowPlaying.playing ? "pause.fill" : "play.fill", size: 22) { perform(.togglePlayPause) }
                        .accessibilityLabel(Strings.playPause)
                    IslandButton(symbol: "forward.fill", size: 16) { perform(.next) }
                        .accessibilityLabel(Strings.next)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 3)
            }
            .padding(.leading, 134 * s)
            .padding(.trailing, 18 * s)
            .padding(.top, 10 * s)
        }
    }
}

private struct SourceLabel: View {
    let name: String
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 5.5, height: 5.5)
            SwapText(text: name, font: .system(size: 10.5, weight: .semibold), color: .white.opacity(0.5))
        }
    }
}

/// Text that blurs out upwards and comes in from below when it changes.
private struct SwapText: View {
    let text: String
    let font: Font
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(text)
                .transition(.asymmetric(
                    insertion: .modifier(active: Slide(offset: 6), identity: Slide(offset: 0)),
                    removal: .modifier(active: Slide(offset: -5), identity: Slide(offset: 0))
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Slide: ViewModifier {
        let offset: CGFloat
        func body(content: Content) -> some View {
            content.offset(y: offset).opacity(offset == 0 ? 1 : 0).blur(radius: offset == 0 ? 0 : 4)
        }
    }
}

private struct ArtworkView: View {
    let nowPlaying: NowPlaying

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.14))
            if let img = nowPlaying.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(img))
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

/// Redraws once per second, only while open and playing.
struct Scrubber: View {
    let nowPlaying: NowPlaying
    let onSeek: (Double) -> Void

    // Built without Xcode, so no @State macro: State is used directly.
    private let draggingState = State<Double?>(initialValue: nil)
    private let hoveringState = State(initialValue: false)
    private var dragging: Double? {
        get { draggingState.wrappedValue }
        nonmutating set { draggingState.wrappedValue = newValue }
    }
    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !nowPlaying.playing || dragging != nil)) { ctx in
            let d = nowPlaying.duration
            let pos = dragging ?? nowPlaying.position(at: ctx.date)
            HStack(spacing: 8) {
                Text(Self.format(pos))
                    .frame(width: Self.labelWidth(duration: d, remaining: false), alignment: .leading)
                GeometryReader { g in
                    let h: CGFloat = hovering || dragging != nil ? 7 : 4.5
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        // Jumps without animation: a spring would bounce on long seeks.
                        Capsule().fill(.white.opacity(0.92))
                            .frame(width: g.size.width * min(1, max(0, pos / d)))
                            .transaction { $0.animation = nil }
                    }
                    .frame(height: h)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = min(1, max(0, v.location.x / g.size.width)) * d }
                        .onEnded { _ in
                            if let t = dragging { onSeek(t) }
                            dragging = nil
                        })
                    .animation(.spring(duration: 0.25, bounce: 0.3), value: h)
                }
                Text("−" + Self.format(d - pos))
                    .frame(width: Self.labelWidth(duration: d, remaining: true), alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .onHover { hovering = $0 }
    }

    static func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return "\(s / 3600):" + String(format: "%02d:%02d", s / 60 % 60, s % 60) }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Wide enough for the longest time the track can show, so the bar keeps still while it plays.
    static func labelWidth(duration: Double, remaining: Bool) -> CGFloat {
        let text = (remaining ? "−" : "") + format(duration)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        return max(remaining ? 34 : 30, ((text as NSString).size(withAttributes: [.font: font]).width).rounded(.up))
    }
}

struct IslandButton: View {
    let symbol: String
    var size: CGFloat = 16
    var diameter: CGFloat = 34
    var dimmed = false
    let action: () -> Void

    // Built without Xcode, so no @State macro: State is used directly.
    private let hoveringState = State(initialValue: false)
    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(hovering: hovering, dimmed: dimmed))
        .onHover { hovering = $0 }
    }

    private struct PressStyle: ButtonStyle {
        let hovering: Bool
        let dimmed: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white.opacity(dimmed && !hovering ? 0.55 : 1))
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
                .animation(.smooth(duration: 0.2), value: hovering)
        }
    }
}

/// Core Animation equalizer: the bars animate in the window server, the app doesn't wake up per frame.
struct EqualizerView: NSViewRepresentable {
    let playing: Bool
    let color: NSColor

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.update(playing: playing, color: color)
    }
}

final class EqualizerNSView: NSView {
    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var playing: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars.forEach { b in
            b.cornerRadius = 1.5
            b.transform = CATransform3DMakeScale(1, 0.25, 1)
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w: CGFloat = 3, gap: CGFloat = 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            b.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            b.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func update(playing: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()

        guard playing != self.playing else { return }
        self.playing = playing
        let patterns: [[CGFloat]] = [
            [0.35, 0.9, 0.5, 1.0, 0.4, 0.75, 0.35],
            [0.6, 0.3, 1.0, 0.55, 0.85, 0.3, 0.6],
            [0.45, 1.0, 0.35, 0.7, 0.5, 0.95, 0.45],
            [0.8, 0.4, 0.65, 0.3, 1.0, 0.5, 0.8],
        ]
        let durations: [CFTimeInterval] = [1.05, 0.9, 1.2, 0.98]
        for (i, b) in bars.enumerated() {
            if playing {
                let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
                a.values = patterns[i]
                a.duration = durations[i]
                a.calculationMode = .cubic
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                b.add(a, forKey: "eq")
            } else {
                let current = b.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? 0.25
                b.removeAnimation(forKey: "eq")
                let settle = CASpringAnimation(keyPath: "transform.scale.y")
                settle.fromValue = current
                settle.toValue = 0.25
                settle.stiffness = 300
                settle.damping = 26
                settle.duration = settle.settlingDuration
                b.add(settle, forKey: "settle")
            }
        }
    }
}
