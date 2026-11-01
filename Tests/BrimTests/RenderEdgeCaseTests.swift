import Testing
import AppKit
import SwiftUI
@testable import Brim

/// Renders the island with extreme content and saves PNGs for review ($REPORT/edge, or /tmp).
/// Checks only that rendering works and draws something; the images are reviewed by eye.
@MainActor
@Suite(.serialized) struct RenderEdgeCaseTests {
    static let out: URL = {
        let base = ProcessInfo.processInfo.environment["REPORT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/brim-edge")
        let url = base.appendingPathComponent("edge")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let notch = IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true)

    init() {
        SnapshotRenderer.isActive = true
        Strings.bundle = Bundle(url: Repo.resources.appendingPathComponent("es.lproj"))!
    }

    @discardableResult
    func render(_ name: String, width: CGFloat = 560, height: CGFloat, _ setup: (IslandModel, IslandScreen) -> Void) -> NSBitmapImageRep? {
        let model = IslandModel()
        let screen = IslandScreen(geometry: notch)
        setup(model, screen)
        let host = NSHostingView(rootView: IslandView(model: model, screen: screen).frame(width: width, height: height).background(Color(white: 0.5)))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent("\(name).png"))
        return rep
    }

    /// Fraction of pixels that are island black, to know something was drawn.
    func blackShare(_ rep: NSBitmapImageRep?) -> Double {
        guard let rep else { return 0 }
        var black = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.redComponent < 0.05, c.greenComponent < 0.05, c.blueComponent < 0.05 { black += 1 }
            }
        }
        return Double(black) / Double(total)
    }

    static func artwork(_ side: Int, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { r in color.setFill(); r.fill(); return true }
    }

    func song(_ title: String, artist: String, artwork: NSImage?) -> NowPlaying {
        NowPlaying(title: title, artist: artist, album: "", duration: 3725, elapsed: 3600, timestamp: Date(), rate: 1, playing: true,
                   appName: "Microsoft Edge", bundleID: nil, artwork: artwork, accent: .white)
    }

    @Test func longTrackInPlayer() {
        let rep = render("player-long-title", height: 180) { m, s in
            m.nowPlaying = song(String(repeating: "Una canción con un título larguísimo ", count: 4), artist: String(repeating: "Artista Invitado feat. ", count: 5), artwork: nil)
            s.expanded = true
        }
        #expect(blackShare(rep) > 0.1)
    }

    @Test func emptyTitles() {
        render("player-empty-title", height: 180) { m, s in m.nowPlaying = song("", artist: "", artwork: nil); s.expanded = true }
        render("compact-empty-title", height: 60) { m, _ in m.nowPlaying = song("", artist: "", artwork: nil); m.mediaVisible = true }
    }

    @Test func hugeAndTinyArtwork() {
        render("player-art-3000", height: 180) { m, s in m.nowPlaying = song("Big cover", artist: "A", artwork: Self.artwork(3000, color: .systemTeal)); s.expanded = true }
        render("player-art-1px", height: 180) { m, s in m.nowPlaying = song("Tiny cover", artist: "A", artwork: Self.artwork(1, color: .systemPink)); s.expanded = true }
        let wide = NSImage(size: NSSize(width: 1600, height: 200), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
        render("player-art-wide", height: 180) { m, s in m.nowPlaying = song("Wide cover", artist: "A", artwork: wide); s.expanded = true }
        render("compact-art-wide", height: 60) { m, _ in m.nowPlaying = song("Wide cover", artist: "A", artwork: wide); m.mediaVisible = true }
    }

    @Test(arguments: [0.0, 0.0625, 0.5, 1.0])
    func hudLevels(level: Double) {
        render("hud-volume-\(level)", height: 90) { m, _ in m.hud = HUDState(kind: .volume, level: level, muted: level == 0) }
        render("hud-brightness-\(level)", height: 90) { m, _ in m.hud = HUDState(kind: .brightness, level: level) }
    }

    @Test func hudMutedWithLevel() {
        render("hud-muted-at-half", height: 90) { m, _ in m.hud = HUDState(kind: .volume, level: 0.5, muted: true) }
    }

    @Test func longDeviceNames() {
        render("device-long-name", height: 120) { m, _ in
            m.device = AudioDeviceEvent(name: "Los AirPods Pro de Andrés Paladino (segunda generación)", status: .connected, battery: 100, visual: .symbol("airpods.pro"))
        }
        render("device-low-1", height: 120) { m, _ in m.device = AudioDeviceEvent(name: "AirPods", status: .lowBattery, battery: 1, visual: .symbol("airpods")) }
        render("device-no-battery", height: 120) { m, _ in m.device = AudioDeviceEvent(name: "HDMI", status: .connected, battery: nil, visual: .symbol("tv")) }
    }

    @Test(arguments: [0, 1, 9, 10, 20, 64, 99, 100])
    func chargePercents(pct: Int) {
        render("charge-plugged-\(pct)", height: 110) { m, _ in m.charge = ChargeEvent(kind: .plugged, percent: pct) }
    }

    @Test func rightToLeftAndEmoji() {
        render("claude-rtl", height: 140) { m, s in
            var n = ClaudeNotice(session: "s", project: "مشروع", kind: .permission(title: "إذن لـ Bash", detail: "rm -rf ./build 🎉🎉🎉", code: true), hostName: nil)
            n.answerable = true
            m.claude = n; s.expanded = true; s.expandedClaude = true
        }
        render("claude-emoji-ear", height: 80) { m, _ in
            m.claude = ClaudeNotice(session: "s", project: "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀", kind: .waiting, hostName: nil)
        }
    }

    @Test func everythingAtOnce() {
        // HUD wins, but the others are loaded underneath.
        let rep = render("stacked", height: 120) { m, _ in
            m.nowPlaying = song("x", artist: "y", artwork: nil); m.mediaVisible = true
            m.recording = ScreenRecording(start: Date(), stoppable: true)
            m.claude = ClaudeNotice(session: "s", project: "brim", kind: .waiting, hostName: nil)
            m.hud = HUDState(kind: .volume, level: 0.3)
        }
        #expect(blackShare(rep) > 0.05)
    }

    @Test func externalDisplayRecordingWithClaude() {
        let flat = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 0, height: 24), hasNotch: false))
        _ = flat
        render("compact-no-artwork", height: 60) { m, _ in m.nowPlaying = song("No art", artist: "x", artwork: nil); m.mediaVisible = true }
    }
}

/// The face draws frames only until its animation ends, so each timeline must be still by then.
@Suite struct FaceTimelineTests {
    @Test(arguments: [ChargeEvent.Kind.plugged, .charged, .unplugged, .low, .full])
    func chargeFaceIsStillAfterItsDuration(_ kind: ChargeEvent.Kind) {
        let end = FaceDrawing.duration(kind)
        let last = FaceDrawing.params(at: end, kind: kind)
        #expect([1, 100, 1000, 60_000].allSatisfy { FaceDrawing.params(at: end + $0, kind: kind) == last })
    }

    @Test(arguments: [false, true])
    func boopFaceIsStillAfterItsDuration(_ annoyed: Bool) {
        let end = FaceDrawing.boopDuration(annoyed: annoyed)
        let last = FaceDrawing.boopParams(at: end, annoyed: annoyed)
        #expect([1, 100, 1000, 60_000].allSatisfy { FaceDrawing.boopParams(at: end + $0, annoyed: annoyed) == last })
    }
}

@Suite struct TimeFormatTests {
    @Test func minutesAndSeconds() {
        #expect(Scrubber.format(0) == "0:00")
        #expect(Scrubber.format(59.9) == "0:59")
        #expect(Scrubber.format(61) == "1:01")
        #expect(Scrubber.format(-5) == "0:00")
    }

    /// Podcasts and long mixes: an hour used to show as "60:00".
    @Test func hours() {
        #expect(Scrubber.format(3599) == "59:59")
        #expect(Scrubber.format(3600) == "1:00:00")
        #expect(Scrubber.format(3725) == "1:02:05")
        #expect(Scrubber.format(36000) == "10:00:00")
    }

    /// The labels fit the longest time of the track: "−59:59" used to be cut in a 34 pt label.
    @Test func labelsFitTheLongestTime() {
        #expect(Scrubber.labelWidth(duration: 198, remaining: false) == 30)
        #expect(Scrubber.labelWidth(duration: 198, remaining: true) == 34)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        for d in [599.0, 3599, 3725, 36000] {
            for remaining in [false, true] {
                let text = (remaining ? "−" : "") + Scrubber.format(d)
                #expect(Scrubber.labelWidth(duration: d, remaining: remaining) >= (text as NSString).size(withAttributes: [.font: font]).width)
            }
        }
    }
}
