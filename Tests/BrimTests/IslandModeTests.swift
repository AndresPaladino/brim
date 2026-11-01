import Testing
import Foundation
@testable import Brim

/// Which face the island shows. Walks every combination of inputs and checks the rules from IslandScreen.mode(of:).
@MainActor
@Suite struct IslandModeTests {
    struct Inputs: CustomTestStringConvertible {
        var hud = false, device = false, charge = false, boop = false, recording = false
        var claude: ClaudeNotice.Kind? = nil
        var music = false, mediaVisible = false, expanded = false, expandedClaude = false, fullscreen = false
        var testDescription: String {
            [hud ? "hud" : nil, device ? "device" : nil, charge ? "charge" : nil, boop ? "boop" : nil, recording ? "rec" : nil,
             claude.map { "claude:\($0)" }, music ? "music" : nil, mediaVisible ? "visible" : nil, expanded ? "open" : nil,
             expandedClaude ? "openClaude" : nil, fullscreen ? "fullscreen" : nil].compactMap { $0 }.joined(separator: "+")
        }
    }

    /// Every combination: 2^10 flags × 3 Claude states = 3072 cases.
    static let all: [Inputs] = {
        var out: [Inputs] = []
        let claudes: [ClaudeNotice.Kind?] = [nil, .permission(title: "t", detail: "d", code: true), .error("e")]
        for bits in 0..<(1 << 10) {
            for c in claudes {
                let b = { (i: Int) in bits & (1 << i) != 0 }
                out.append(Inputs(hud: b(0), device: b(1), charge: b(2), boop: b(3), recording: b(4), claude: c,
                                  music: b(5), mediaVisible: b(6), expanded: b(7), expandedClaude: b(8), fullscreen: b(9)))
            }
        }
        return out
    }()

    static func mode(_ i: Inputs) -> IslandMode {
        let model = IslandModel()
        let now = Date()
        if i.hud { model.hud = HUDState(kind: .volume, level: 0.5) }
        if i.device { model.device = AudioDeviceEvent(name: "AirPods", status: .connected, battery: 50, visual: .symbol("airpods")) }
        if i.charge { model.charge = ChargeEvent(kind: .plugged, percent: 50) }
        if i.boop { model.boop = BoopEvent(annoyed: false) }
        if i.recording { model.recording = ScreenRecording(start: now, stoppable: true) }
        if let kind = i.claude { model.claude = ClaudeNotice(session: "s", project: "p", kind: kind, hostName: nil) }
        if i.music { model.nowPlaying = track(at: now) }
        model.mediaVisible = i.mediaVisible
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true))
        screen.expanded = i.expanded
        screen.expandedClaude = i.expandedClaude
        screen.fullscreen = i.fullscreen
        return screen.mode(of: model)
    }

    @Test func alertsWinInOrder() {
        for i in Self.all {
            let m = Self.mode(i)
            if i.hud { #expect(m == .hud, "\(i.testDescription)") }
            else if i.device { #expect(m == .device, "\(i.testDescription)") }
            else if i.charge { #expect(m == .charge, "\(i.testDescription)") }
            else if i.boop { #expect(m == .boop, "\(i.testDescription)") }
        }
    }

    @Test func fullscreenNeverShowsMusic() {
        for i in Self.all where i.fullscreen {
            let m = Self.mode(i)
            #expect(m != .media && m != .compact, "\(i.testDescription) -> \(m)")
        }
    }

    @Test func recordingOwnsTheEarsUntilClicked() {
        for i in Self.all where i.recording && !i.hud && !i.device && !i.charge && !i.boop && !i.expanded {
            #expect(Self.mode(i) == .recording, "\(i.testDescription)")
        }
    }

    @Test func eachModeHasWhatItShows() {
        for i in Self.all {
            switch Self.mode(i) {
            case .media: #expect(i.music && i.expanded && !i.fullscreen, "\(i.testDescription)")
            case .compact: #expect(i.music && i.mediaVisible && !i.expanded && !i.fullscreen, "\(i.testDescription)")
            case .claude: #expect(i.claude != nil && i.expanded && i.expandedClaude, "\(i.testDescription)")
            case .claudeEar: #expect(i.claude != nil && !i.expanded, "\(i.testDescription)")
            case .recording: #expect(i.recording, "\(i.testDescription)")
            default: break
            }
        }
    }

    @Test func claudeShowsInFullscreen() {
        for i in Self.all where i.claude != nil && i.fullscreen && !i.hud && !i.device && !i.charge && !i.boop && !i.recording && !i.expanded {
            #expect(Self.mode(i) == .claudeEar, "\(i.testDescription)")
        }
    }

    @Test func nothingMeansIdle() {
        #expect(Self.mode(Inputs()) == .idle)
        #expect(Self.mode(Inputs(music: true)) == .idle) // playing but artwork hidden (paused long ago)
        #expect(Self.mode(Inputs(music: true, mediaVisible: true)) == .compact)
        #expect(Self.mode(Inputs(mediaVisible: true)) == .idle) // stale flag without a track
    }

    /// A Claude alert should never vanish while nothing else covers it. Skips states the window code
    /// never produces: the player open without music (nowPlayingChanged collapses it) or in full screen
    /// (setFullscreen collapses it).
    @Test func claudeAlertIsAlwaysVisibleSomehow() {
        for i in Self.all where i.claude != nil && !i.hud && !i.device && !i.charge && !i.boop {
            let m = Self.mode(i)
            let reachable = !(i.expanded && !i.expandedClaude && (!i.music || i.fullscreen))
            guard reachable else { continue }
            #expect(m != .idle, "\(i.testDescription)")
        }
    }
}
