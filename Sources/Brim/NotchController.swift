import AppKit
import SwiftUI

/// Owns the shared services (keys, music, devices, Claude Code) and one island per display.
@MainActor
final class NotchController {
    private let model = IslandModel()
    private let prefs = Preferences.shared
    private lazy var presenter = IslandPresenter(model: model, prefs: prefs)
    private var windows: [IslandWindow] = []

    private var keyTap: MediaKeyTap?
    private var accessibilityObserver: NSObjectProtocol?
    private let nowPlaying = NowPlayingService()
    private let audioDevices = AudioDeviceMonitor()
    private let fullscreen = FullscreenMonitor()
    private let power = PowerMonitor()
    private lazy var claude = ClaudeCenter(model: model)
    private let recording = ScreenRecordingMonitor()

    init() {
        rebuildWindows()
        prefs.onDisplaysChange = { [weak self] in self?.rebuildWindows() }
        prefs.onMediaAtRestChange = { [weak self] in self?.presenter.updateMediaVisibility() }
        IslandMenu.shared.onOpenSettings = { [weak self] in self?.collapseAll() }

        keyTap = MediaKeyTap { [weak self] key, fine in
            MainActor.assumeIsolated { self?.handle(key, fine: fine) ?? false }
        }
        startKeyTap()

        presenter.onLayoutChange = { [weak self] in self?.windows.forEach { $0.refreshHotRect() } }
        presenter.closePlayer = { [weak self] in self?.windows.filter { $0.screen.expanded && !$0.screen.expandedClaude }.forEach { $0.setExpanded(false) } }
        presenter.sendMedia = { [weak self] in self?.nowPlaying.send($0) }
        presenter.openPlayingApp = { [weak self] in self?.openPlayingApp() }
        model.perform = { [weak self] in self?.presenter.perform($0) }
        nowPlaying.onChange = { [weak self] in self?.nowPlayingChanged($0) }
        nowPlaying.start()

        audioDevices.onConnect = { [weak self] event in
            guard let self, self.prefs.deviceAlerts else { return }
            self.presenter.showDevice(event)
        }
        audioDevices.start()

        fullscreen.onChange = { [weak self] _ in self?.applyFullscreen() }
        fullscreen.start()

        power.onEvent = { [weak self] in self?.presenter.power($0) }
        power.start()

        recording.onChange = { [weak self] _ in self?.applyRecording() }
        prefs.onScreenRecordingChange = { [weak self] in self?.applyRecording() }
        recording.start()

        model.claudeAnswer = { [weak self] id, allow in self?.claude.answer(id, allow: allow) }
        model.claudeChoose = { [weak self] id, labels in self?.claude.choose(id, labels: labels) }
        model.claudeFocus = { [weak self] id in self?.claudeFocus(id) }
        claude.isOpen = { [weak self] in self?.windows.contains { $0.screen.expanded && $0.screen.expandedClaude } ?? false }
        claude.onChange = { [weak self] in self?.claudeChanged() }
        prefs.onClaudeChange = { [weak self] in self?.claude.refresh() }
        claude.refresh()
        if DebugTools.enabled {
            // Commands from scripts/dev/brimctl.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.andrespaladino.brim.debug"), object: nil, queue: .main) { [weak self] note in
                let command = note.object as? String ?? ""
                MainActor.assumeIsolated { self?.debugCommand(command) }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }

        // open Brim.app --args --demo-device shows the device alert without connecting anything.
        if CommandLine.arguments.contains("--demo-device") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                let visual: AudioDeviceEvent.Visual = DeviceArtwork.buds(productID: 0x2027)
                    .map { .buds(left: $0.left, right: $0.right) } ?? .symbol("airpods.pro")
                self?.presenter.showDevice(AudioDeviceEvent(name: "Andres’s AirPods Pro 3", status: .connected, battery: 76, visual: visual))
            }
        }
    }

    /// Displays, resolution or lid changed.
    func reposition() { rebuildWindows() }

    private func rebuildWindows() {
        let targets = NotchMetrics.targets(for: prefs.displays)
        guard targets != windows.map(\.metrics) else { return }
        windows.forEach { $0.close() }
        windows = targets.map { IslandWindow(metrics: $0, model: model) }
        windows.forEach {
            $0.onBoop = { [weak self] in self?.presenter.boop() }
            $0.onClaudeClick = { [weak self] in if let id = self?.model.claude?.id { self?.claudeFocus(id) } }
            $0.onStopRecording = { [weak self] in self?.recording.stop() }
        }
        fullscreen.refresh()
        applyFullscreen()
    }

    private func applyFullscreen() {
        windows.forEach { $0.setFullscreen(fullscreen.displays.contains($0.metrics.displayID)) }
    }

    private func didWake() {
        keyTap?.ensureEnabled()
        nowPlaying.refresh()
        rebuildWindows()
        fullscreen.refresh()
        applyFullscreen()
    }

    private func collapseAll() { windows.forEach { $0.setExpanded(false) } }

    // MARK: - Now Playing

    private func nowPlayingChanged(_ incoming: NowPlaying?) {
        // Check headphone battery on track changes instead of waking up just for it.
        if presenter.nowPlayingChanged(incoming), prefs.lowBattery, let low = audioDevices.lowBatteryEvent() {
            presenter.showDevice(low)
        }
    }

    // MARK: - Claude Code

    private func claudeChanged() {
        windows.forEach { $0.refreshHotRect() }
        if model.claude?.expandable != true {
            windows.filter { $0.screen.expanded && $0.screen.expandedClaude }.forEach { $0.setExpanded(false) }
        }
    }

    private func debugCommand(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "snapshot":
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/brim-build/snapshots").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let name = parts.count > 1 ? parts[1] : "island"
            for (i, window) in windows.enumerated() {
                window.snapshot(to: "\(dir)/\(name)-\(i).png")
                let mouse = NSEvent.mouseLocation
                let state = "mode=\(window.screen.mode(of: model)) fullscreen=\(window.screen.fullscreen) open=\(window.screen.expanded) claude=\(window.screen.expandedClaude) " +
                    "alert=\(model.claude.map { "\($0.kind)".prefix(30) } ?? "-") " +
                    "recording=\(model.recording.map { $0.stoppable ? "macOS" : "other" } ?? "-") " +
                    "processes=\(ScreenRecordingMonitor.processNames().filter { $0.lowercased().contains("screencapture") }.sorted()) cursor=\(Int(mouse.x)),\(Int(mouse.y)) " +
                    "cursorInHotZone=\(window.cursorInHotZone)\n"
                try? state.write(toFile: "\(dir)/\(name)-\(i).txt", atomically: true, encoding: .utf8)
            }
        case "hover":
            for window in windows {
                window.debugPinned = true
                if model.claude?.expandable == true { window.setExpanded(true, claude: true) }
                else if model.nowPlaying != nil { window.setExpanded(true) }
            }
        case "leave":
            windows.forEach { $0.debugPinned = false }
            collapseAll()
        case "focus":
            if let id = model.claude?.id { claudeFocus(id) }
        case "autoanswer":
            ClaudeCenter.debugAutoAnswer = parts.count > 1 && parts[1] == "on"
        case "capture":
            // capture on|off: the island shows up in screen recordings, and the real recording
            // indicator stays hidden so it doesn't sit in the ears for the whole video.
            captureMode = parts.count > 1 && parts[1] == "on"
            windows.forEach { $0.setCapturable(captureMode) }
            if captureMode { withAnimation(.smooth) { model.recording = nil } }
        case "hud":
            // hud volume|brightness <0-1>
            let args = parts.count > 1 ? parts[1].split(separator: " ") : []
            let level = args.count > 1 ? Double(args[1]) ?? 0.5 : 0.5
            presenter.showHUD(HUDState(kind: args.first == "brightness" ? .brightness : .volume, level: level), bump: false)
        case "device":
            let buds = DeviceArtwork.buds(productID: 0x2027).map { AudioDeviceEvent.Visual.buds(left: $0.left, right: $0.right) }
            presenter.showDevice(AudioDeviceEvent(name: "AirPods Pro", status: .connected, battery: 76, visual: buds ?? .symbol("airpods.pro")))
        case "charge":
            let kind: ChargeEvent.Kind = switch parts.count > 1 ? parts[1] : "" {
            case "full": .full; case "unplugged": .unplugged; case "low": .low; default: .plugged }
            presenter.showCharge(ChargeEvent(kind: kind, percent: kind == .low ? 10 : kind == .full ? 80 : 64))
        case "boop":
            presenter.boop()
        case "music":
            // music on|off: a sample track with drawn artwork, nothing real playing needed.
            if parts.count > 1, parts[1] == "on" {
                let song = NowPlaying(title: "Ciudad dormida", artist: "Nadia Ferro", album: "", duration: 198, elapsed: 74,
                                      timestamp: Date(), rate: 1, playing: true, appName: "Music", bundleID: nil,
                                      artwork: SnapshotRenderer.sampleArtwork, accent: Color(red: 1, green: 0.62, blue: 0.42))
                withAnimation(.snappy) { model.nowPlaying = song }
                presenter.setMediaVisible(true)
            } else {
                presenter.nowPlayingChanged(nil) // as when the real music stops
            }
            windows.forEach { $0.refreshHotRect() }
        case "media":
            // media toggle|next|prev: controls whatever is playing, like the player buttons.
            switch parts.count > 1 ? parts[1] : "" {
            case "next": presenter.perform(.next)
            case "prev": presenter.perform(.previous)
            default: presenter.perform(.togglePlayPause)
            }
        case "rec":
            // Fake recording, to test the timer without recording.
            let arg = parts.count > 1 ? parts[1] : "on"
            withAnimation(.snappy) { model.recording = arg == "off" ? nil : ScreenRecording(start: Date(), stoppable: arg != "other") }
            windows.forEach { $0.refreshHotRect() }
        case "stats":
            // stats [reset]: frames drawn by the critter, the pompom and the face since launch (or the last reset).
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/brim-build/snapshots").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if parts.count > 1, parts[1] == "reset" { CritterDrawing.frames = 0; FaceDrawing.frames = 0 }
            try? "critter=\(CritterDrawing.frames) face=\(FaceDrawing.frames)\n".write(toFile: "\(dir)/frames.txt", atomically: true, encoding: .utf8)
        case "state":
            // state: everything scripts/test/e2e needs to check, as JSON in snapshots/state.json.
            writeState()
        case "answer":
            // answer allow|deny: like clicking ✓ or ✕ on the current alert.
            if let id = model.claude?.id { claude.answer(id, allow: parts.count > 1 && parts[1] == "allow") }
        case "choose":
            // choose <label>[,<label>]: picks options of the current question.
            if let id = model.claude?.id, parts.count > 1 { claude.choose(id, labels: parts[1].components(separatedBy: ",")) }
        case "click":
            // click: a click on the notch of the first display (boop, open, or jump to the terminal).
            windows.first?.debugClick()
        default:
            break
        }
    }

    private func writeState() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/brim-build/snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claudeKind: String? = model.claude.map {
            switch $0.kind {
            case .permission: "permission"
            case .question: "question"
            case .done: "done"
            case .waiting: "waiting"
            case .error: "error"
            }
        }
        var usage = rusage_info_current()
        let rss = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        } == 0 ? Int(usage.ri_phys_footprint) : -1
        let state: [String: Any] = [
            "windows": windows.map { w in [
                "mode": "\(w.screen.mode(of: model))", "open": w.screen.expanded, "openClaude": w.screen.expandedClaude,
                "fullscreen": w.screen.fullscreen, "display": Int(w.metrics.displayID), "notch": w.metrics.geometry.hasNotch,
            ] as [String: Any] },
            "hud": model.hud.map { "\($0.kind) \($0.level) muted=\($0.muted)" } ?? NSNull(),
            "device": model.device?.name ?? NSNull(),
            "charge": model.charge.map { "\($0.kind)" } ?? NSNull(),
            "boop": model.boop.map { $0.annoyed ? "annoyed" : "boop" } ?? NSNull(),
            "claude": claudeKind ?? NSNull(),
            "claudeSession": model.claude?.session ?? NSNull(),
            "claudeAnswerable": model.claude?.answerable ?? false,
            "recording": model.recording.map { $0.stoppable ? "macOS" : "other" } ?? NSNull(),
            "music": model.nowPlaying.map { "\($0.title)" } ?? NSNull(),
            "playing": model.nowPlaying?.playing ?? false,
            "mediaVisible": model.mediaVisible,
            "stretch": Double(model.stretch),
            "footprintBytes": rss,
            "bridgePID": nowPlaying.bridgePID ?? -1,
            "frames": ["critter": CritterDrawing.frames, "face": FaceDrawing.frames],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    private func claudeFocus(_ id: UUID) {
        claude.focus(id)
        collapseAll()
    }

    // MARK: - Screen recording

    private var captureMode = false

    private func applyRecording() {
        guard !captureMode else { return }
        let current = prefs.screenRecording ? recording.current : nil
        guard model.recording != current else { return }
        withAnimation(current != nil ? .snappy : .smooth) { model.recording = current }
        windows.forEach { $0.refreshHotRect() }
    }

    // MARK: - Boop

    /// The face waves at the end of onboarding.
    func greet() { presenter.boop() }

    private func openPlayingApp() {
        guard let id = model.nowPlaying?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        collapseAll()
    }

    // MARK: - Volume and brightness keys

    /// Starts the key tap as soon as Accessibility is granted (macOS posts a notification).
    private func startKeyTap() {
        // During onboarding, its own button triggers the system prompt.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !OnboardingWindow.shouldShow] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt), keyTap?.start() == true { return }
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.retryKeyTap() }
            }
        }
    }

    private func retryKeyTap() {
        guard AXIsProcessTrusted(), keyTap?.start() == true else { return }
        if let accessibilityObserver { DistributedNotificationCenter.default().removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
    }

    private func handle(_ key: MediaKey, fine: Bool) -> Bool {
        guard prefs.volumeHUD else { return false }
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard SystemVolume.isControllable else { return false }
            let change = IslandPresenter.volumeChange(key, volume: SystemVolume.volume, muted: SystemVolume.isMuted, fine: fine)
            if let volume = change.setVolume { SystemVolume.volume = volume }
            if let muted = change.setMuted { SystemVolume.isMuted = muted }
            presenter.showHUD(HUDState(kind: .volume, level: Double(change.level), muted: change.muted), bump: change.atLimit)

        case .brightnessUp, .brightnessDown:
            guard DisplayBrightness.isControllable else { return false }
            let old = DisplayBrightness.brightness
            let level = IslandPresenter.stepped(old, up: key == .brightnessUp, fine: fine)
            DisplayBrightness.brightness = level
            presenter.showHUD(HUDState(kind: .brightness, level: Double(level)), bump: level == old)
        }
        return true
    }
}
