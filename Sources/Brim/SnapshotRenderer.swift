import AppKit
import SwiftUI

/// Development tool: renders the island to a PNG with the app's own views, without the real event.
///   Brim --render-device <out.png> [airpods|jbl|wired|usb|low]
@MainActor
enum SnapshotRenderer {
    /// While active, views start in their final state.
    nonisolated(unsafe) static var isActive = false
    /// Moment (ms) of the face animation to render.
    nonisolated(unsafe) static var faceTime: Double = 2400

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-readme"), i + 1 < args.count {
            renderReadme(to: args[i + 1]); return true
        }
        if let i = args.firstIndex(of: "--codex-hooks"), i + 1 < args.count {
            // --codex-hooks connect|disconnect|status (use BRIM_CODEX_HOME to test on a copy)
            do {
                switch args[i + 1] {
                case "connect": try CodexHooks.connect()
                case "disconnect": try CodexHooks.disconnect()
                default: break
                }
                print(CodexHooks.isConnected ? "conectado" : "sin conectar")
            } catch {
                print("error: \(error)")
            }
            return true
        }
        if let i = args.firstIndex(of: "--claude-hooks"), i + 1 < args.count {
            // --claude-hooks connect|disconnect|status (use BRIM_CLAUDE_SETTINGS to test on a copy)
            do {
                switch args[i + 1] {
                case "connect": try ClaudeHooks.connect()
                case "disconnect": try ClaudeHooks.disconnect()
                default: break
                }
                print(ClaudeHooks.isConnected ? "conectado" : "sin conectar")
            } catch {
                print("error: \(error)")
            }
            return true
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            // --render-settings <png> [general|alerts|claude]
            let name = i + 2 < args.count ? args[i + 2] : "general"
            renderSettings(to: args[i + 1], tab: name == "alerts" ? .alerts : name == "claude" ? .claude : .general); return true
        }
        if let i = args.firstIndex(of: "--render-onboarding"), i + 1 < args.count {
            let name = i + 2 < args.count ? args[i + 2] : "welcome"
            let step: OnboardingModel.Step = switch name {
            case "access": .accessibility; case "bt": .bluetooth; case "conflict": .conflict("MediaMate"); case "notch": .notch
            case "features": .features; case "agents": .agents; case "done": .done; default: .welcome }
            let host = NSHostingView(rootView: OnboardingView(model: OnboardingModel(snapshot: step)))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            save(host, to: args[i + 1]); return true
        }
        if let i = args.firstIndex(of: "--render-boop"), i + 1 < args.count {
            renderBoop(to: args[i + 1], at: i + 2 < args.count ? Double(args[i + 2]) ?? 1300 : 1300,
                       annoyed: args.contains("annoyed")); return true
        }
        if let i = args.firstIndex(of: "--render-recording"), i + 1 < args.count {
            // --render-recording <png> [other] [claude] [external]
            renderRecording(to: args[i + 1], options: Array(args[(i + 2)...])); return true
        }
        if let i = args.firstIndex(of: "--render-charge"), i + 1 < args.count {
            renderCharge(to: args[i + 1], kind: i + 2 < args.count ? args[i + 2] : "full"); return true
        }
        if let i = args.firstIndex(of: "--render-claude"), i + 1 < args.count {
            // --render-claude <png> <kind> [open] [ms] [music] [external] [noapprove] [yes|no] [codex] [project=…]
            renderClaude(to: args[i + 1], options: Array(args[(i + 2)...])); return true
        }
        if let i = args.firstIndex(of: "--render-external"), i + 1 < args.count {
            renderExternal(to: args[i + 1], mode: i + 2 < args.count ? args[i + 2] : "hud"); return true
        }
        guard let i = args.firstIndex(of: "--render-device"), i + 1 < args.count else { return false }
        isActive = true
        let kind = i + 2 < args.count ? args[i + 2] : "airpods"
        let model = IslandModel()
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true))
        let buds = DeviceArtwork.buds(productID: 0x2027).map { AudioDeviceEvent.Visual.buds(left: $0.left, right: $0.right) }
        model.device = switch kind {
        case "jbl": AudioDeviceEvent(name: "JBL Charge 5", status: .connected, battery: nil, visual: .symbol(DeviceSymbols.forBluetoothClass(0x05)))
        case "wired": AudioDeviceEvent(name: Strings.headphones, status: .connected, battery: nil, visual: .symbol("headphones"))
        case "usb": AudioDeviceEvent(name: "UM2", status: .connected, battery: nil, visual: .symbol(DeviceSymbols.pick("hifireceiver.fill")))
        case "low": AudioDeviceEvent(name: "Andres’s AirPods Pro 3", status: .lowBattery, battery: 8, visual: buds ?? .symbol("airpods.pro"))
        default: AudioDeviceEvent(name: "Andres’s AirPods Pro 3", status: .connected, battery: 76, visual: buds ?? .symbol("airpods.pro"))
        }
        let view = IslandView(model: model, screen: screen)
            .frame(width: 460, height: 130)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        return true
    }

    /// Settings uses AppKit controls, so it renders the real window, toolbar included.
    private static func renderSettings(to path: String, tab: SettingsTab) {
        let w = SettingsWindow.snapshotWindow(tab: tab)
        w.orderFrontRegardless()
        w.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        save(w.contentView?.superview ?? w.contentView!, to: path)
        w.orderOut(nil)
    }

    /// README images: every feature on the same backdrop. Brim --render-readme <dir>
    private static func renderReadme(to dir: String) {
        isActive = true
        faceTime = 2400
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let notch = IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true)
        let song = NowPlaying(title: "Ciudad dormida", artist: "Nadia Ferro", album: "", duration: 198, elapsed: 74,
                              timestamp: Date(), rate: 1, playing: true, appName: "Music", bundleID: nil,
                              artwork: sampleArtwork, accent: Color(red: 1, green: 0.62, blue: 0.42))
        let buds = DeviceArtwork.buds(productID: 0x2027).map { AudioDeviceEvent.Visual.buds(left: $0.left, right: $0.right) }

        // --wallpaper <png>: a 16" MacBook Pro wallpaper at 1.35× zoom, matching the website loop videos.
        let args = CommandLine.arguments
        let wallpaper = args.firstIndex(of: "--wallpaper").flatMap { $0 + 1 < args.count ? NSImage(contentsOfFile: args[$0 + 1]) : nil }
        let zoom: CGFloat = wallpaper == nil ? 1 : 1.35

        func shot(_ name: String, height: CGFloat, _ setup: (IslandModel, IslandScreen) -> Void) {
            let model = IslandModel()
            let screen = IslandScreen(geometry: notch)
            setup(model, screen)
            let size = CGSize(width: 640 / zoom, height: height)
            let background: AnyView = if let wallpaper {
                AnyView(Image(nsImage: wallpaper).resizable().frame(width: 1728, height: 1117)
                    .frame(width: size.width, height: size.height, alignment: .top).clipped())
            } else {
                AnyView(backdrop)
            }
            let view = IslandView(model: model, screen: screen)
                .frame(width: size.width, height: size.height)
                .background(background)
            let host = NSHostingView(rootView: view)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            save(host, to: "\(dir)/\(name).png")
        }

        shot("volume", height: 100) { m, _ in m.hud = HUDState(kind: .volume, level: 0.6) }
        shot("player", height: 172) { m, s in m.nowPlaying = song; s.expanded = true }
        shot("playing", height: 58) { m, _ in m.nowPlaying = song; m.mediaVisible = true }
        shot("airpods", height: 120) { m, _ in
            m.device = AudioDeviceEvent(name: "AirPods Pro", status: .connected, battery: 76, visual: buds ?? .symbol("airpods.pro"))
        }
        shot("charging", height: 114) { m, _ in m.charge = ChargeEvent(kind: .plugged, percent: 64) }
        shot("recording", height: 58) { m, _ in m.recording = ScreenRecording(start: Date().addingTimeInterval(-73), stoppable: true) }
        shot("claude-permission", height: 116) { m, s in
            var n = ClaudeNotice(session: "s", project: "brim", kind: { let d = ClaudeCenter.describe(tool: "Bash", input: ["command": "swift build && swift test"]); return .permission(title: d.0, detail: d.1, code: d.2) }(), hostName: "iTerm")
            n.answerable = true
            m.claude = n; s.expanded = true; s.expandedClaude = true
        }
        shot("claude-question", height: 248) { m, s in
            var n = ClaudeNotice(session: "s", project: "brim", kind: .question(ClaudeQuestion(text: "Which style should the notch character use?", options: [
                .init(label: "Pixel", detail: "Hard edges, like the terminal one"), .init(label: "Smooth", detail: "Rounded corners"),
                .init(label: "Both", detail: "A setting to switch between them")], multi: false, count: 1)), hostName: "iTerm")
            n.answerable = true
            m.claude = n; s.expanded = true; s.expandedClaude = true
        }
        shot("claude-done", height: 124) { m, s in
            m.claude = ClaudeNotice(session: "s", project: "brim", kind: .done(summary: ClaudeCenter.summary(of: "Done.\n\nFixed the progress bar bounce and ran the tests: all 48 pass."), minutes: 4), hostName: "iTerm")
            s.expanded = true; s.expandedClaude = true
        }
    }

    /// Soft desktop-like gradient behind the README images.
    private static var backdrop: some View {
        ZStack {
            Color(red: 0.23, green: 0.16, blue: 0.36)
            RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.38), .clear], center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.31, green: 0.49, blue: 1), .clear], center: UnitPoint(x: 0.92, y: 0), startRadius: 0, endRadius: 420)
        }
    }

    /// Artwork drawn in code, so no real album cover ends up in the repo.
    static let sampleArtwork: NSImage = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
        let gradient = NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.4, alpha: 1), NSColor(red: 0.42, green: 0.27, blue: 0.62, alpha: 1)])
        gradient?.draw(in: rect, angle: -60)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 180, y: 170, width: 70, height: 70)).fill()
        NSColor(red: 0.16, green: 0.12, blue: 0.3, alpha: 0.9).setFill()
        let hills = NSBezierPath()
        hills.move(to: .zero)
        hills.curve(to: NSPoint(x: 300, y: 70), controlPoint1: NSPoint(x: 90, y: 150), controlPoint2: NSPoint(x: 200, y: 20))
        hills.line(to: NSPoint(x: 300, y: 0))
        hills.close()
        hills.fill()
        return true
    }

    /// The island on a display without a notch (24 pt menu bar).
    private static func renderExternal(to path: String, mode: String) {
        isActive = true
        let model = IslandModel()
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 0, height: 24), hasNotch: false))
        model.nowPlaying = NowPlaying(title: "Ciudad dormida", artist: "Nadia Ferro", album: "", duration: 198, elapsed: 60,
                                      timestamp: Date(), rate: 1, playing: true, appName: "Spotify", bundleID: nil, artwork: nil, accent: .orange)
        switch mode {
        case "compact": model.mediaVisible = true
        case "media": screen.expanded = true
        case "idle": break
        case "empty": model.nowPlaying = nil
        default: model.hud = HUDState(kind: .volume, level: 0.6)
        }
        let view = IslandView(model: model, screen: screen)
            .frame(width: 520, height: 190)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    private static func renderCharge(to path: String, kind: String) {
        isActive = true
        let model = IslandModel()
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true))
        let k: ChargeEvent.Kind = switch kind { case "plugged": .plugged; case "unplugged": .unplugged; case "low": .low; default: .full }
        model.charge = ChargeEvent(kind: k, percent: k == .unplugged ? 64 : k == .low ? 10 : 80)
        let view = IslandView(model: model, screen: screen)
            .frame(width: 460, height: 120)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    private static func renderRecording(to path: String, options: [String]) {
        isActive = true
        let model = IslandModel()
        let external = options.contains("external")
        let geometry = external ? IslandGeometry(notch: CGSize(width: 0, height: 24), hasNotch: false)
                                : IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true)
        let screen = IslandScreen(geometry: geometry)
        model.recording = ScreenRecording(start: Date().addingTimeInterval(-73), stoppable: !options.contains("other"))
        if options.contains("claude") { model.claude = ClaudeNotice(session: "s", project: "brim", kind: .waiting, hostName: "VS Code") }
        let view = IslandView(model: model, screen: screen)
            .frame(width: 460, height: 80)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    /// A Claude Code alert, in the ear or open, frozen at one moment. Includes edge cases.
    private static func renderClaude(to path: String, options: [String]) {
        isActive = true
        faceTime = options.compactMap(Double.init).first ?? 2400
        let has = { options.contains($0) }
        let model = IslandModel()
        let notch = has("external") ? CGSize(width: 0, height: 24) : CGSize(width: 188, height: 33.5)
        let screen = IslandScreen(geometry: IslandGeometry(notch: notch, hasNotch: !has("external")))
        if has("music") {
            model.nowPlaying = NowPlaying(title: "Golden Hour", artist: "JVKE", album: "", duration: 198, elapsed: 60,
                                          timestamp: Date(), rate: 1, playing: true, appName: "Spotify", bundleID: nil, artwork: nil, accent: .orange)
            model.mediaVisible = true
        }
        let perm = { (d: (String, String, Bool)) -> ClaudeNotice.Kind in .permission(title: d.0, detail: d.1, code: d.2) }
        let kind: ClaudeNotice.Kind = switch options.first ?? "permission" {
        case "permission-long": perm((String(format: Strings.claudePermissionFor, "Bash"),
            "find . -name '*.swift' -not -path './.build/*' | xargs grep -n 'withAnimation' | sort | uniq -c | head -50", true))
        case "edit": perm(ClaudeCenter.describe(tool: "Edit", input: ["file_path": "/x/NotchController.swift", "old_string": "a\nb\nc", "new_string": "a\nb\nc\nd\ne"]))
        case "write": perm(ClaudeCenter.describe(tool: "Write", input: ["file_path": "/x/ClaudeIntegrationTestsForTheNotchIsland.swift", "content": "1\n2\n3"]))
        case "web": perm(ClaudeCenter.describe(tool: "WebFetch", input: ["url": "https://developer.apple.com/documentation/appkit/nspanel"]))
        case "patch": perm(ClaudeCenter.describeCodex(tool: "apply_patch", input: ["command": "*** Begin Patch\n*** Update File: Sources/Brim/NotchController.swift\n@@\n-a\n+b\n+c\n*** Update File: Sources/Brim/IslandView.swift\n@@\n+d\n*** End Patch"]))
        case "mcp": perm(ClaudeCenter.describe(tool: "mcp__claude_ai_Google_Calendar__create_event", input: ["description": "Create event: Networks midterm"]))
        case "question": .question(ClaudeQuestion(text: "Which style should the notch character use?", options: [
            .init(label: "Pixel", detail: "Hard edges, like the terminal one"), .init(label: "Smooth", detail: "Rounded corners"),
            .init(label: "Both", detail: "A setting to switch between them")], multi: false, count: 1))
        case "question-multi": .question(ClaudeQuestion(text: "Which alerts should also show on the external display?", options: [
            .init(label: "Volume", detail: "The volume and brightness HUD"), .init(label: "Music", detail: "Artwork and equalizer"),
            .init(label: "Claude", detail: "The critter and its alerts"), .init(label: "Charging", detail: "The face when you plug in")], multi: true, count: 1))
        case "question-3lines": .question(ClaudeQuestion(text: "There are two ways to store the preferences: UserDefaults as now, or a JSON file you can copy between Macs. Which one do you prefer?", options: [
            .init(label: "UserDefaults", detail: "No extra files"), .init(label: "JSON file", detail: "Easy to copy to another Mac")], multi: false, count: 1))
        case "question-long": .question(ClaudeQuestion(text: "Before I go on, should alerts also appear on the external display when the lid is closed, or only on the built-in screen, and should that be a setting?",
            options: ["Every display", "Built-in only", "External only", "Ask me later", "Other"].map { .init(label: $0, detail: "") }, multi: false, count: 1))
        case "question-wide": .question(ClaudeQuestion(text: "De las 20 ideas para el personaje de Codex, ¿cuáles te gustan más, aunque sea por un solo detalle?", options: [
            .init(label: "Animales", detail: "Gato, Búho, Pingüino, Rana, Pollito o Pececito"), .init(label: "Criaturas flotantes", detail: "Fantasmita, Medusa, Murciélago o Abejita"),
            .init(label: "Objetos con cara", detail: "Foquito, Engranaje, Planetita, Hongo o Cactus"), .init(label: "Bichos raros", detail: "Slime, Cíclope, Pulpito, Mariquita o Nube de lluvia")], multi: true, count: 1))
        case "codex-question": .question(ClaudeQuestion(text: "Favorite color?", options: [
            .init(label: "Blue (Recommended)", detail: "Matches the pompom"), .init(label: "Red", detail: "Matches Claude")], multi: false, count: 1))
        case "done": .done(summary: ClaudeCenter.summary(of: "Done.\n\nFixed the progress bar bounce and ran the tests: all 48 pass."), minutes: 4)
        case "done-long": .done(summary: ClaudeCenter.summary(of: "All done.\n\n```swift\nlet x = 1\n```\n\nI went through the 11 files, updated the Spanish and English strings, added the Settings section with its two toggles and tested the hook installer on a copy of your config. Do you want me to install it now or review the diff first?"), minutes: 37)
        case "done-short": .done(summary: ClaudeCenter.summary(of: "Done."), minutes: nil)
        case "waiting": .waiting
        case "error": .error("API Error: Rate limit reached")
        case "error-long": .error("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")
        default: perm(ClaudeCenter.describe(tool: "Bash", input: ["command": "npm run build && swift test"]))
        }
        let project = options.first { $0.hasPrefix("project=") }.map { String($0.dropFirst(8)) } ?? "brim"
        var notice = ClaudeNotice(session: "s", project: project, kind: kind, hostName: has("codex") ? "Codex" : "VS Code")
        if has("codex") { notice.agent = .codex }
        notice.answerable = !has("noapprove")
        if has("yes") || has("no") { notice.answered = (has("yes"), Date().addingTimeInterval(-0.15)) }
        // chosen=A,B: question already answered with those options.
        if let chosen = options.first(where: { $0.hasPrefix("chosen=") }) {
            notice.chosen = chosen.dropFirst(7).split(separator: ",").map(String.init)
            notice.answered = (true, Date().addingTimeInterval(-0.15))
        }
        model.claude = notice
        let height = max(180, ClaudeLayout.size(notice, notch: CGSize(width: 188, height: 33.5)).height + 40)
        if has("open") { screen.expanded = true; screen.expandedClaude = true }
        let view = IslandView(model: model, screen: screen)
            .frame(width: 560, height: height)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    private static func renderBoop(to path: String, at ms: Double, annoyed: Bool) {
        isActive = true
        faceTime = ms
        let model = IslandModel()
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true))
        model.boop = BoopEvent(annoyed: annoyed)
        let view = IslandView(model: model, screen: screen)
            .frame(width: 360, height: 110)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.3), Color(red: 0.3, green: 0.35, blue: 0.8)],
                                       startPoint: .leading, endPoint: .trailing))
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
