import SwiftUI

enum HUDKind { case volume, brightness }

struct HUDState: Equatable {
    var kind: HUDKind
    var level: Double
    var muted = false
}

enum IslandMode { case idle, compact, hud, device, charge, boop, media, claudeEar, claude, recording }

/// State shared by every island (one per display).
@MainActor
final class IslandModel: ObservableObject {
    /// Volume or brightness HUD. Takes priority over everything else.
    @Published var hud: HUDState?
    @Published var stretch: CGFloat = 0
    @Published var nowPlaying: NowPlaying?
    /// Artwork and equalizer next to the notch while playing, and for a while after pausing.
    @Published var mediaVisible = false
    @Published var device: AudioDeviceEvent?
    @Published var charge: ChargeEvent?
    @Published var boop: BoopEvent?
    @Published var claude: ClaudeNotice?
    @Published var recording: ScreenRecording?
    var perform: (MediaCommand) -> Void = { _ in }
    var claudeAnswer: (UUID, Bool) -> Void = { _, _ in }
    var claudeChoose: (UUID, [String]) -> Void = { _, _ in }
    var claudeFocus: (UUID) -> Void = { _ in }
}

/// Per-display state: geometry and whether the island is open there.
@MainActor
final class IslandScreen: ObservableObject {
    @Published var expanded = false
    /// The open drop is Claude's, not the player.
    @Published var expandedClaude = false
    /// A full screen app is showing here: hide the ears and the player.
    @Published var fullscreen = false
    let geometry: IslandGeometry

    init(geometry: IslandGeometry) { self.geometry = geometry }

    func mode(of model: IslandModel) -> IslandMode {
        if model.hud != nil { return .hud }
        if model.device != nil { return .device }
        if model.charge != nil { return .charge }
        if model.boop != nil { return .boop }
        // While recording, the ears belong to the timer, even in full screen. Music and Claude open on click.
        if model.recording != nil {
            if expanded, expandedClaude, model.claude != nil { return .claude }
            if expanded, !expandedClaude, model.nowPlaying != nil, !fullscreen { return .media }
            return .recording
        }
        // Claude shows in full screen too: it may be waiting for a permission.
        if model.claude != nil {
            if expanded, expandedClaude { return .claude }
            if !expanded { return .claudeEar }
        }
        // In full screen only the alerts above show.
        guard !fullscreen, model.nowPlaying != nil else { return .idle }
        if expanded { return .media }
        return model.mediaVisible ? .compact : .idle
    }
}

/// Island sizes for one display. Without a notch the island is hidden at rest (height 0) and grows
/// from the top edge, as tall as the menu bar.
struct IslandGeometry: Equatable {
    let notch: CGSize
    let hasNotch: Bool

    /// Hover strip on displays without a notch while the island is hidden.
    static let hoverStrip = CGSize(width: 160, height: 6)

    func size(_ mode: IslandMode, claude: ClaudeNotice? = nil) -> CGSize {
        switch mode {
        case .claudeEar:
            CGSize(width: hasNotch ? notch.width + ClaudeLayout.earWidth(claude) * 2 : 110 + ClaudeLayout.earWidth(claude), height: notch.height)
        case .claude: ClaudeLayout.size(claude, notch: notch)
        case .idle: hasNotch ? notch : CGSize(width: 110, height: 0)
        case .recording:
            CGSize(width: (hasNotch ? notch.width : 16) + IslandLayout.recordingEarWidth(claude: claude != nil) * 2, height: notch.height)
        case .compact: CGSize(width: hasNotch ? notch.width + IslandLayout.compactEarWidth * 2 : 128, height: notch.height)
        case .hud: CGSize(width: IslandLayout.hudWidth, height: notch.height + IslandLayout.hudContentHeight)
        case .device: CGSize(width: IslandLayout.deviceWidth, height: notch.height + IslandLayout.deviceContentHeight)
        case .charge: CGSize(width: IslandLayout.chargeWidth, height: notch.height + IslandLayout.chargeContentHeight)
        case .boop: CGSize(width: max(notch.width + 26, 120), height: notch.height + IslandLayout.boopContentHeight)
        case .media: IslandLayout.mediaSize(notch: notch)
        }
    }
}

enum IslandLayout {
    static let scale: CGFloat = 0.9
    static let ear: CGFloat = 7
    /// Slightly rounder than the physical notch, so it hides behind it at rest.
    static let idleRadius: CGFloat = 12

    // Volume and brightness
    static let hudWidth: CGFloat = 320 * scale
    static let hudContentHeight: CGFloat = 46 * scale
    static let hudRadius: CGFloat = 24 * scale

    // Audio devices: wider than the HUD to fit names like "Andres’s AirPods Pro 3"
    static let deviceWidth: CGFloat = 340
    static let deviceContentHeight: CGFloat = 60

    // Charging
    static let chargeWidth: CGFloat = 300
    static let chargeContentHeight: CGFloat = 54

    // Boop
    static let boopContentHeight: CGFloat = 46
    static let boopRadius: CGFloat = 20

    // Ears while music plays
    static let compactEarWidth: CGFloat = 42 * scale

    // Screen recording: stop button on the left, timer on the right
    static func recordingEarWidth(claude: Bool) -> CGFloat { claude ? 56 : 46 }

    // Player
    static let mediaWidth: CGFloat = 440 * scale
    static let mediaContentHeight: CGFloat = 124 * scale
    static let mediaRadius: CGFloat = 30 * scale

    static func mediaSize(notch: CGSize) -> CGSize {
        CGSize(width: mediaWidth, height: notch.height + mediaContentHeight)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var screen: IslandScreen

    private func showsHoverStrip(mode: IslandMode) -> Bool {
        !screen.geometry.hasNotch && !screen.fullscreen && mode == .idle && model.nowPlaying != nil
    }

    var body: some View {
        let notch = screen.geometry.notch
        let mode = screen.mode(of: model)
        let size = screen.geometry.size(mode, claude: model.claude)
        let radius: CGFloat = switch mode {
        case .idle, .compact, .claudeEar, .recording: IslandLayout.idleRadius
        case .claude: ClaudeLayout.radius
        case .hud, .device, .charge: IslandLayout.hudRadius
        case .media: IslandLayout.mediaRadius
        case .boop: IslandLayout.boopRadius
        }
        let ear = mode == .idle ? 0 : IslandLayout.ear
        let shape = NotchShape(ear: ear, bottomRadius: radius)
        let lifted = mode != .idle && mode != .compact && mode != .claudeEar && mode != .recording
        // With a Claude alert in the ear, the critter replaces the artwork and the equalizer stays.
        let musicEars = model.mediaVisible && !screen.fullscreen
        let mediaMode: IslandMode = switch mode {
        case .claudeEar: musicEars ? .compact : .idle
        case .claude, .recording: .idle
        default: mode
        }

        let width = size.width + model.stretch + ear * 2
        // Content goes in an overlay so it can never grow the black shape. A hidden equalizer once
        // stretched it into a visible strip at rest.
        shape
            .fill(.black)
            .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: lifted ? 18 : 0, y: lifted ? 7 : 0)
            .frame(width: width, height: size.height)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if let np = model.nowPlaying {
                        MediaLayer(nowPlaying: np, mode: mediaMode, notch: notch, hideArt: mode == .claudeEar, perform: model.perform)
                            .padding(.horizontal, ear)
                    }
                    if let event = model.device, model.hud == nil {
                        DeviceContent(event: event)
                            .id(event.id)
                            .frame(width: IslandLayout.deviceWidth, height: IslandLayout.deviceContentHeight)
                            .padding(.top, notch.height)
                            .transition(.asymmetric(
                                insertion: .blurFade.animation(.snappy),
                                removal: .blurFade.animation(.smooth(duration: 0.25))
                            ))
                    }
                    if let event = model.charge, model.hud == nil, model.device == nil {
                        ChargeContent(event: event)
                            .id(event.id)
                            .frame(width: IslandLayout.chargeWidth, height: IslandLayout.chargeContentHeight)
                            .padding(.top, notch.height)
                            .transition(.asymmetric(
                                insertion: .blurFade.animation(.snappy),
                                removal: .blurFade.animation(.smooth(duration: 0.25))
                            ))
                    }
                    if let event = model.boop, model.hud == nil, model.device == nil, model.charge == nil {
                    BoopContent(event: event)
                        .id(event.id)
                        .frame(height: IslandLayout.boopContentHeight)
                        .padding(.top, notch.height)
                        .transition(.asymmetric(
                            insertion: .blurFade.animation(.snappy),
                            removal: .blurFade.animation(.smooth(duration: 0.25))
                        ))
                }
                if let notice = model.claude, mode == .claudeEar {
                    ClaudeEarContent(notice: notice, showsLabel: !(model.nowPlaying != nil && musicEars), notchHeight: notch.height)
                        .frame(width: size.width)
                        .transition(.opacity.animation(.smooth(duration: 0.2)))
                }
                if let notice = model.claude, mode == .claude {
                    ClaudeOpenContent(notice: notice,
                                      answer: { model.claudeAnswer(notice.id, $0) },
                                      choose: { model.claudeChoose(notice.id, $0) },
                                      focus: { model.claudeFocus(notice.id) })
                        .id(notice.id)
                        .frame(width: size.width, height: ClaudeLayout.content(notice).height)
                        .padding(.top, notch.height)
                        .transition(.asymmetric(
                            insertion: .blurFade.animation(.snappy),
                            removal: .blurFade.animation(.smooth(duration: 0.22))
                        ))
                }
                if let recording = model.recording, mode == .recording {
                    RecordingEars(recording: recording, claudeDot: model.claude?.agent.tint, notchHeight: notch.height)
                        .frame(width: size.width)
                        .transition(.opacity.animation(.smooth(duration: 0.2)))
                }
                if model.claude != nil, mode == .media {
                    // A Claude alert arrived while the player is open: show a dot, keep the player.
                    Circle().fill(model.claude?.agent.tint ?? CritterDrawing.clay).frame(width: 7, height: 7)
                        .padding(.trailing, 46)
                        .frame(width: size.width, height: notch.height, alignment: .trailing)
                        .transition(.opacity)
                }
                if let hud = model.hud {
                        HUDContent(state: hud)
                            .frame(width: IslandLayout.hudWidth, height: IslandLayout.hudContentHeight)
                            .padding(.top, notch.height)
                            .transition(.asymmetric(
                                insertion: .blurFade.animation(.snappy),
                                removal: .blurFade.animation(.smooth(duration: 0.25))
                            ))
                    }
                }
                .frame(width: width, height: size.height, alignment: .top)
                .clipShape(shape)
            }
            .overlay(alignment: .top) {
                // Fully transparent pixels don't get mouse events, so the hover strip is almost invisible instead.
                if showsHoverStrip(mode: mode) {
                    Color.black.opacity(0.005).frame(width: IslandGeometry.hoverStrip.width, height: IslandGeometry.hoverStrip.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Screen recording

struct RecordingEars: View {
    let recording: ScreenRecording
    /// Color of the agent's dot, when one has an alert.
    let claudeDot: Color?
    let notchHeight: CGFloat

    static let red = Color(red: 1, green: 0.27, blue: 0.23)

    static func elapsed(since start: Date, at date: Date) -> String {
        let t = max(0, Int(date.timeIntervalSince(start).rounded(.down)))
        let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let earWidth = IslandLayout.recordingEarWidth(claude: claudeDot != nil)
        HStack(spacing: 0) {
            Group {
                if recording.stoppable {
                    // Drawing only. IslandWindow handles the click.
                    Circle().fill(Self.red)
                        .overlay(RoundedRectangle(cornerRadius: 1.6, style: .continuous).fill(.white).frame(width: 7, height: 7))
                        .frame(width: 19, height: 19)
                } else {
                    Circle().fill(Self.red).frame(width: 8, height: 8)
                }
            }
            .frame(width: earWidth)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                if let claudeDot { Circle().fill(claudeDot).frame(width: 6, height: 6) }
                // One redraw per second. Text(timerInterval:) used about 0.5% CPU constantly.
                TimelineView(.periodic(from: recording.start, by: 1)) { ctx in
                    Text(Self.elapsed(since: recording.start, at: ctx.date))
                }
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
            }
            .frame(width: earWidth)
        }
        .frame(height: notchHeight)
    }
}

// MARK: - HUD

struct HUDContent: View {
    let state: HUDState

    private var shownLevel: Double { state.muted ? 0 : state.level }

    private var symbol: String {
        switch state.kind {
        case .volume: return state.muted || state.level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        case .brightness: return state.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol, variableValue: state.kind == .volume ? shownLevel : nil)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
            LevelBar(level: shownLevel)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }
}

struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white)
                        .frame(width: g.size.width * min(1, max(0, level)))
                }
        }
        .frame(height: 6)
    }
}

// MARK: - Transitions and shape

/// Blur, fade and scale from the top.
private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 7 : 0)
            .scaleEffect(active ? 0.84 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

/// Notch outline: concave top corners (radius `ear`) and rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottomRadius) }
        set { ear = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, ear), w = rect.width, h = rect.height
        let r = max(0, min(bottomRadius, (w - 2 * t) / 2, h - t))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addArc(tangent1End: CGPoint(x: t, y: 0), tangent2End: CGPoint(x: t, y: h), radius: t)
        p.addArc(tangent1End: CGPoint(x: t, y: h), tangent2End: CGPoint(x: w - t, y: h), radius: r)
        p.addArc(tangent1End: CGPoint(x: w - t, y: h), tangent2End: CGPoint(x: w - t, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: w - t, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: t)
        p.closeSubpath()
        return p
    }
}
