import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.andrespaladino.brim", category: "nowplaying")

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var playing: Bool
    var appName: String?
    var bundleID: String?
    var artwork: NSImage?
    var accent: Color

    var trackID: String { "\(title)|\(artist)|\(album)" }

    /// Current position, extrapolated from the last update.
    func position(at date: Date) -> Double {
        guard playing else { return elapsed }
        let p = elapsed + date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }
}

enum MediaCommand {
    case togglePlayPause, next, previous
    case seek(Double)
    /// Brings the playing app forward. Doesn't go through the bridge.
    case openApp
}

/// Keeps the bridge (perl + NowPlayingBridge.dylib) running and decodes its messages.
@MainActor
final class NowPlayingService {
    var onChange: ((NowPlaying?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var current: NowPlaying?
    private var restarts = 0

    func start() {
        guard process == nil,
              let dylib = Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "dylib"),
              let script = Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "pl")
        else { log.error("Bridge missing from Resources"); return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, dylib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        // Split lines and decode artwork off the main thread so a track change never stalls an animation.
        let parser = LineParser()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for message in parser.feed(data) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(message.object, artwork: message.artwork) } }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bridgeEnded() } }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            log.error("Could not launch the bridge: \(error.localizedDescription)")
        }
    }

    /// Asks the bridge for the full state, e.g. after wake. Relaunches it if it gave up after crashing.
    func refresh() {
        guard process != nil else { restarts = 0; start(); return }
        try? input?.write(contentsOf: Data("refresh\n".utf8))
    }

    func send(_ command: MediaCommand) {
        let line: String = switch command {
        case .togglePlayPause: "toggle"
        case .next: "next"
        case .previous: "prev"
        case .seek(let t): "seek \(t)"
        case .openApp: "refresh"
        }
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func bridgeEnded() {
        process = nil
        input = nil
        guard restarts < 5 else { log.error("The bridge crashed too many times"); return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func apply(_ o: [String: Any], artwork: (image: NSImage, accent: NSColor)?) {
        if let error = o["error"] as? String { log.error("Bridge: \(error)"); return }
        guard o["active"] as? Bool == true else {
            current = nil
            onChange?(nil)
            return
        }
        restarts = 0
        var np = NowPlaying(
            title: o["title"] as? String ?? "",
            artist: o["artist"] as? String ?? "",
            album: o["album"] as? String ?? "",
            duration: o["duration"] as? Double ?? 0,
            elapsed: o["elapsed"] as? Double ?? 0,
            timestamp: Date(timeIntervalSince1970: o["timestamp"] as? Double ?? Date().timeIntervalSince1970),
            rate: o["rate"] as? Double ?? 0,
            playing: (o["playing"] as? Bool) ?? ((o["playing"] as? Int ?? 0) != 0),
            appName: Self.appName(bundle: o["bundle"] as? String, pid: o["pid"] as? Int),
            bundleID: (o["bundle"] as? String) ?? (o["pid"] as? Int).flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.bundleIdentifier },
            artwork: nil,
            accent: .white
        )
        if let artwork {
            np.artwork = artwork.image
            np.accent = Color(nsColor: artwork.accent)
        } else if let current, current.trackID == np.trackID {
            np.artwork = current.artwork
            np.accent = current.accent
        }
        current = np
        onChange?(np)
    }

    private static func appName(bundle: String?, pid: Int?) -> String? {
        var name: String?
        if let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            name = app.localizedName
        } else if let pid, pid > 0 {
            name = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
        }
        return name.map(shortName)
    }

    /// La oreja izquierda es angosta: "Microsoft Edge" → "Edge", "Google Chrome" → "Chrome".
    private static func shortName(_ name: String) -> String {
        for prefix in ["Microsoft ", "Google ", "Mozilla "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// Dominant artwork color, brightened to read on black.
    nonisolated static func accent(of image: NSImage) -> NSColor {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Saturation-weighted average, so vivid colors win over grays.
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let pr = Double(px[i]) / 255, pg = Double(px[i + 1]) / 255, pb = Double(px[i + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let w = 0.05 + (mx > 0 ? (mx - mn) / mx : 0) * mx
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        let avg = NSColor(srgbRed: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, s * 1.25), brightness: max(0.82, v), alpha: 1)
    }
}

/// Splits the bridge's JSON lines and prepares artwork off the main thread.
/// Only used by the pipe's readability handler, which macOS calls serially.
private final class LineParser: @unchecked Sendable {
    struct Message { let object: [String: Any]; let artwork: (image: NSImage, accent: NSColor)? }
    private var buffer = Data()

    func feed(_ data: Data) -> [Message] {
        buffer.append(data)
        var out: [Message] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            var artwork: (NSImage, NSColor)?
            if let b64 = obj["artwork"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Decode to a bitmap here so SwiftUI doesn't do it on the main thread.
                let decoded = NSImage(cgImage: cg, size: img.size)
                artwork = (decoded, NowPlayingService.accent(of: decoded))
            }
            out.append(Message(object: obj, artwork: artwork))
        }
        return out
    }
}
