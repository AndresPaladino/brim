import Testing
import Foundation
import AppKit
@testable import Brim

/// Logic around system events: power, full screen, media keys, displays, login item, headphone battery.
@MainActor
@Suite struct SystemLogicTests {
    typealias R = (onAC: Bool, charging: Bool, charged: Bool, percent: Int)
    func ev(_ last: (Bool, Bool, Int), _ now: R) -> PowerMonitor.Event? {
        PowerMonitor.event(from: (last.0, last.1, last.2), to: now)
    }

    @Test func powerTransitions() {
        guard case .plugged(50, false)? = ev((false, false, 50), (true, false, false, 50)) else { Issue.record("plug"); return }
        guard case .plugged(100, true)? = ev((false, false, 100), (true, false, false, 100)) else { Issue.record("plug full"); return }
        guard case .plugged(80, true)? = ev((false, false, 80), (true, false, true, 80)) else { Issue.record("plug charged"); return }
        guard case .unplugged(70)? = ev((true, true, 70), (false, false, false, 70)) else { Issue.record("unplug"); return }
        guard case .full(80)? = ev((true, true, 79), (true, false, false, 80)) else { Issue.record("full"); return }
        #expect(ev((true, false, 80), (true, false, false, 80)) == nil) // nothing changed
        #expect(ev((true, false, 80), (true, true, false, 80)) == nil) // charging resumed
        #expect(ev((false, false, 50), (false, false, false, 49)) == nil) // just draining
    }

    @Test func lowBatteryCrossings() {
        guard case .low(20)? = ev((false, false, 21), (false, false, false, 20)) else { Issue.record("20"); return }
        guard case .low(10)? = ev((false, false, 11), (false, false, false, 10)) else { Issue.record("10"); return }
        guard case .low(9)? = ev((false, false, 25), (false, false, false, 9)) else { Issue.record("jump past both"); return }
        #expect(ev((false, false, 20), (false, false, false, 19)) == nil) // already alerted at 20
        #expect(ev((true, true, 21), (true, true, false, 20)) == nil) // on AC: no low alert
    }

    /// A day of battery: one event per real change, nothing in between.
    @Test func batteryDayProducesFewEvents() {
        var last = (onAC: true, charging: true, percent: 50)
        var events: [String] = []
        func step(_ onAC: Bool, _ charging: Bool, _ pct: Int) {
            if let e = PowerMonitor.event(from: last, to: (onAC, charging, false, pct)) { events.append("\(e)") }
            last = (onAC, charging, pct)
        }
        for p in 50...80 { step(true, p < 80, p) }        // charges to the 80 % limit
        for p in stride(from: 80, through: 5, by: -1) { step(false, false, p) } // unplugged, drains
        step(true, false, 5)                               // plugged in again
        #expect(events.count == 5, "\(events)") // full, unplugged, low 20, low 10, plugged
    }

    @Test func fullscreenSpaces() {
        let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2
        let ids = ["UUID-A": a, "UUID-B": b]
        let space = { (type: Int, id: String) -> [String: Any] in ["Current Space": ["type": type], "Display Identifier": id] }
        #expect(FullscreenMonitor.fullscreenDisplays(in: [space(0, "UUID-A"), space(4, "UUID-B")], byUUID: ids) == [b])
        #expect(FullscreenMonitor.fullscreenDisplays(in: [space(4, "Main")], byUUID: ids) == [a, b])
        #expect(FullscreenMonitor.fullscreenDisplays(in: [space(4, "UNKNOWN")], byUUID: ids) == [])
        #expect(FullscreenMonitor.fullscreenDisplays(in: [["garbage": 1]], byUUID: ids) == [])
        #expect(FullscreenMonitor.fullscreenDisplays(in: [], byUUID: ids) == [])
    }

    @Test func mediaKeyDecoding() {
        let data1 = { (code: Int, state: Int) in (code << 16) | (state << 8) }
        #expect(MediaKeyTap.decode(data1: data1(0, 0xA))! == (0, true))
        #expect(MediaKeyTap.decode(data1: data1(7, 0xB))! == (7, false))
        #expect(MediaKeyTap.decode(data1: data1(0, 0xC)) == nil)
    }

    @Test func mediaKeyUpIsSwallowedOnlyAfterItsDown() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap { key, _ in handled.append(key); return key != .brightnessUp }
        #expect(tap.handle(code: 0, down: true, fine: false))   // volume up: consumed
        #expect(tap.handle(code: 0, down: false, fine: false))  // and its key up too
        #expect(!tap.handle(code: 0, down: false, fine: false)) // a stray key up passes
        #expect(!tap.handle(code: 2, down: true, fine: false))  // handler declined
        #expect(!tap.handle(code: 2, down: false, fine: false))
        #expect(!tap.handle(code: 16, down: true, fine: false)) // play/pause: not ours
        #expect(handled == [.volumeUp, .brightnessUp])
        for (code, key) in [(1, MediaKey.volumeDown), (7, .mute), (3, .brightnessDown)] {
            handled = []
            _ = tap.handle(code: code, down: true, fine: true)
            #expect(handled == [key])
        }
    }

    @Test func notchMetrics() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let m = NotchMetrics.make(displayID: 1, frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
                                  safeTop: 32, leftArea: 640, rightArea: 645, isBuiltIn: true)
        #expect(m.geometry.hasNotch && m.geometry.notch == CGSize(width: 185, height: 32))
        #expect(m.centerX == 640 + 92.5)
        let ext = NotchMetrics.make(displayID: 2, frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
                                    visibleFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1415), safeTop: 0, leftArea: nil, rightArea: nil, isBuiltIn: false)
        #expect(!ext.geometry.hasNotch && ext.geometry.notch.height == 25 && ext.centerX == 1470 + 1280)
        // Menu bar hidden: falls back to 24 pt.
        let hidden = NotchMetrics.make(displayID: 3, frame: frame, visibleFrame: frame, safeTop: 0, leftArea: nil, rightArea: nil, isBuiltIn: false)
        #expect(hidden.geometry.notch.height == 24)
    }

    /// With a notch but no auxiliary areas reported, the notch used to span the whole screen.
    @Test func notchWithoutAuxiliaryAreas() {
        let frame = CGRect(x: 100, y: 0, width: 1470, height: 956)
        for (left, right) in [(nil, nil), (640, nil), (nil, 645), (0, 0)] as [(CGFloat?, CGFloat?)] {
            let m = NotchMetrics.make(displayID: 1, frame: frame, visibleFrame: .zero, safeTop: 32, leftArea: left, rightArea: right, isBuiltIn: true)
            #expect(m.geometry.notch.width == 185 && m.centerX == frame.midX, "\(String(describing: left)), \(String(describing: right))")
        }
    }

    @Test func displayChoice() {
        let builtIn = NotchMetrics.make(displayID: 1, frame: .init(x: 0, y: 0, width: 100, height: 100), visibleFrame: .zero, safeTop: 32, leftArea: 40, rightArea: 40, isBuiltIn: true)
        let ext = NotchMetrics.make(displayID: 2, frame: .init(x: 100, y: 0, width: 100, height: 100), visibleFrame: .zero, safeTop: 0, leftArea: nil, rightArea: nil, isBuiltIn: false)
        #expect(NotchMetrics.pick([builtIn, ext], choice: .all).count == 2)
        #expect(NotchMetrics.pick([builtIn, ext], choice: .builtIn) == [builtIn])
        #expect(NotchMetrics.pick([builtIn, ext], choice: .external) == [ext])
        // Lid closed, "built-in only": falls back to the first display instead of nothing.
        #expect(NotchMetrics.pick([ext], choice: .builtIn) == [ext])
        #expect(NotchMetrics.pick([], choice: .all).isEmpty)
    }

    @Test func loginItemOnFirstLaunch() {
        #expect(LoginItem.shouldEnableOnFirstLaunch(configured: false, bundlePath: "/Applications/Brim.app"))
        #expect(!LoginItem.shouldEnableOnFirstLaunch(configured: true, bundlePath: "/Applications/Brim.app"))
        #expect(!LoginItem.shouldEnableOnFirstLaunch(configured: false, bundlePath: "/Users/me/Downloads/Brim.app"))
        #expect(!LoginItem.shouldEnableOnFirstLaunch(configured: false, bundlePath: "/Volumes/Brim/Brim.app"))
    }

    @Test func headphoneLowBattery() {
        var alerted = Set<String>()
        let check = { (pct: Int, uid: String) in AudioDeviceMonitor.shouldAlertLowBattery(pct, uid: uid, alerted: &alerted) }
        #expect(!check(50, "a"))
        #expect(check(10, "a"))
        #expect(!check(8, "a"))  // once
        #expect(!check(15, "a")) // between 10 and 20: still quiet
        #expect(check(9, "b"))   // other device
        #expect(!check(25, "a")) // charged: rearms
        #expect(check(7, "a"))
    }

    @Test func deviceSymbols() {
        #expect(DeviceSymbols.forName("Andrés's AirPods Pro") == "airpods.pro")
        #expect(DeviceSymbols.forName("AirPods Max")?.contains("airpods") == true)
        #expect(DeviceSymbols.forName("JBL Flip") == nil)
        #expect(DeviceSymbols.looksLikeHeadphones("USB Headset") && DeviceSymbols.looksLikeHeadphones("Auriculares"))
        #expect(!DeviceSymbols.looksLikeHeadphones("Studio Display Speakers"))
        #expect(DeviceSymbols.forBluetoothClass(0x08) == "car.fill")
        #expect(DeviceSymbols.pick("not.a.symbol.at.all") == "headphones")
        for id in [0x2002, 0x2027, 0x200A, 0x2011] {
            let s = DeviceSymbols.forApple(productID: id)!
            #expect(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, "\(s) missing on this macOS")
        }
    }
}

/// NowPlaying math and the bridge's line protocol.
@MainActor
@Suite struct NowPlayingTests {
    /// The bridge used to give up for good after five crashes, until the next wake.
    @Test func bridgeKeepsRestarting() {
        #expect((1...5).allSatisfy { NowPlayingService.restartDelay(after: $0) == 2 })
        #expect(NowPlayingService.restartDelay(after: 6) == 4)
        #expect(NowPlayingService.restartDelay(after: 9) == 32)
        #expect(NowPlayingService.restartDelay(after: 100) == 300)
    }

    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func position() {
        var np = track(elapsed: 10, duration: 100, at: t0)
        #expect(np.position(at: t0.addingTimeInterval(5)) == 15)
        #expect(np.position(at: t0.addingTimeInterval(500)) == 100) // clamped
        #expect(np.position(at: t0.addingTimeInterval(-50)) == 0)   // clock skew
        np.playing = false
        #expect(np.position(at: t0.addingTimeInterval(5)) == 10)
        np.playing = true; np.rate = 2
        #expect(np.position(at: t0.addingTimeInterval(5)) == 20)
        np.rate = 0 // some players report 0 while playing
        #expect(np.position(at: t0.addingTimeInterval(5)) == 15)
        np.duration = 0 // live streams
        #expect(np.position(at: t0.addingTimeInterval(500)) == 510)
    }

    @Test func trackIdentity() {
        #expect(track("A", at: t0).trackID == track("A", elapsed: 99, at: t0).trackID)
        #expect(track("A", at: t0).trackID != track("B", at: t0).trackID)
    }

    @Test func lineParserHandlesChunks() {
        let lines = [#"{"active":true,"title":"One"}"#, "garbage", #"{"active":false}"#, #"{"title":"Ünïcødé 🎵"}"#]
        let stream = Data((lines.joined(separator: "\n") + "\n").utf8)
        // Same messages whatever the chunk boundaries.
        for size in [1, 2, 3, 7, 64, stream.count] {
            let parser = LineParser()
            var got: [String] = []
            var i = 0
            while i < stream.count {
                let chunk = stream.subdata(in: i..<min(stream.count, i + size))
                got += parser.feed(chunk).map { ($0.object["title"] as? String) ?? "-" }
                i += size
            }
            #expect(got == ["One", "-", "Ünïcødé 🎵"], "chunk size \(size)")
        }
    }

    @Test func lineParserDecodesArtwork() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor.systemRed.setFill(); r.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let line = "{\"active\":true,\"artwork\":\"\(png.base64EncodedString())\"}\n"
        let message = try #require(LineParser().feed(Data(line.utf8)).first)
        let art = try #require(message.artwork)
        #expect(art.image.size == NSSize(width: 64, height: 64))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        art.accent.usingColorSpace(.sRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #expect(s > 0.5 && b >= 0.82) // a vivid red, brightened to read on black
        #expect(LineParser().feed(Data("{\"artwork\":\"not base64!\"}\n".utf8)).first?.artwork == nil)
    }

    @Test func grayArtworkGivesNearWhite() {
        let gray = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor(white: 0.4, alpha: 1).setFill(); r.fill(); return true }
        let c = NowPlayingService.accent(of: gray).usingColorSpace(.genericGamma22Gray)!
        #expect(abs(c.whiteComponent - 0.92) < 0.01)
    }

    /// Artwork used to be kept at full size: a 3000 px cover stayed a 3000 px bitmap in memory, shown at 90 pt.
    @Test func bigArtworkIsDownsampled() throws {
        let side = 3000
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]))
        let message = LineParser().feed(Data("{\"artwork\":\"\(png.base64EncodedString())\"}\n".utf8)).first
        let cg = message?.artwork?.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #expect(cg?.width == LineParser.artworkPixels, "decoded width \(cg?.width ?? 0)")
    }

    @Test func smallAndWideArtworkKeepTheirShape() throws {
        for (w, h) in [(60, 60), (1600, 200)] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let cg = try #require(LineParser.thumbnail(png))
            #expect(cg.width == min(w, LineParser.artworkPixels) && cg.height == h * cg.width / w, "\(w)×\(h) → \(cg.width)×\(cg.height)")
        }
    }
}
