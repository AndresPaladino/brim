import AppKit
import SwiftUI

/// Owns the shared services (keys, music, devices, Claude Code) and one island per display.
@MainActor
final class NotchController {
    private let model = IslandModel()
    private let prefs = Preferences.shared
    private var windows: [IslandWindow] = []

    private static let hudDuration: TimeInterval = 1.6
    private var keyTap: MediaKeyTap?
    private var accessibilityObserver: NSObjectProtocol?
    private var hudHide: DispatchWorkItem?

    /// After pausing, the artwork stays next to the notch this long.
    private static let pausedLinger: TimeInterval = 30
    private let nowPlaying = NowPlayingService()

    private static let deviceDuration: TimeInterval = 3.2
    private let audioDevices = AudioDeviceMonitor()
    private var deviceHide: DispatchWorkItem?
    private var pausedHide: DispatchWorkItem?

    private let fullscreen = FullscreenMonitor()
    private let power = PowerMonitor()
    private var chargeHide: DispatchWorkItem?
    private lazy var claude = ClaudeCenter(model: model)
    private let recording = ScreenRecordingMonitor()

    init() {
        rebuildWindows()
        prefs.onDisplaysChange = { [weak self] in self?.rebuildWindows() }
        prefs.onMediaAtRestChange = { [weak self] in self?.updateMediaVisibility() }
        IslandMenu.shared.onOpenSettings = { [weak self] in self?.collapseAll() }

        keyTap = MediaKeyTap { [weak self] key, fine in
            MainActor.assumeIsolated { self?.handle(key, fine: fine) ?? false }
        }
        startKeyTap()

        model.perform = { [weak self] in self?.perform($0) }
        nowPlaying.onChange = { [weak self] in self?.nowPlayingChanged($0) }
        nowPlaying.start()

        audioDevices.onConnect = { [weak self] event in
            guard let self, self.prefs.deviceAlerts else { return }
            self.showDevice(event)
        }
        audioDevices.start()

        fullscreen.onChange = { [weak self] _ in self?.applyFullscreen() }
        fullscreen.start()

        power.onEvent = { [weak self] event in
            guard let self else { return }
            if case .low = event {} else if !self.prefs.chargeAlerts { return }
            switch event {
            case .plugged(let pct, let full): self.showCharge(ChargeEvent(kind: full ? .charged : .plugged, percent: pct))
            case .unplugged(let pct): self.showCharge(ChargeEvent(kind: .unplugged, percent: pct))
            case .full(let pct): self.showCharge(ChargeEvent(kind: .full, percent: pct))
            case .low(let pct):
                guard self.prefs.macLowBattery else { return }
                self.showCharge(ChargeEvent(kind: .low, percent: pct))
            }
        }
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
                self?.showDevice(AudioDeviceEvent(name: "Andres’s AirPods Pro 3", status: .connected, battery: 76, visual: visual))
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
            $0.onBoop = { [weak self] in self?.boop() }
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
        let np = correctingStaleSeek(incoming)
        let old = model.nowPlaying
        let appearing = old == nil || old?.trackID != np?.trackID
        withAnimation(appearing ? .snappy : .smooth) { model.nowPlaying = np }
        // Check headphone battery on track changes instead of waking up just for it.
        if appearing, np != nil, prefs.lowBattery, let low = audioDevices.lowBatteryEvent() { showDevice(low) }
        if np == nil { collapseAll() }
        // On displays without a notch the hover area depends on whether something is playing.
        if (old == nil) != (np == nil) { windows.forEach { $0.refreshHotRect() } }

        updateMediaVisibility()
    }

    private func updateMediaVisibility() {
        pausedHide?.cancel()
        guard prefs.mediaAtRest, let np = model.nowPlaying else { setMediaVisible(false); return }
        if np.playing {
            setMediaVisible(true)
        } else if model.mediaVisible {
            let work = DispatchWorkItem { [weak self] in self?.setMediaVisible(false) }
            pausedHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedLinger, execute: work)
        }
    }

    private func setMediaVisible(_ visible: Bool) {
        guard model.mediaVisible != visible else { return }
        withAnimation(visible ? .snappy : .smooth) { model.mediaVisible = visible }
        windows.forEach { $0.refreshHotRect() }
    }

    /// After a seek, MediaRemote can report the old position for a moment. Ignore mismatches meanwhile.
    private var pendingSeek: (target: Double, at: Date)?

    private func correctingStaleSeek(_ incoming: NowPlaying?) -> NowPlaying? {
        guard var np = incoming, let seek = pendingSeek else { return incoming }
        let now = Date()
        let age = now.timeIntervalSince(seek.at)
        guard age < 2, np.trackID == model.nowPlaying?.trackID else { pendingSeek = nil; return incoming }
        let expected = seek.target + (np.playing ? age : 0)
        if abs(np.position(at: now) - expected) > 1.5 {
            np.elapsed = expected
            np.timestamp = now
        } else {
            pendingSeek = nil
        }
        return np
    }

    private func perform(_ command: MediaCommand) {
        if case .openApp = command { openPlayingApp(); return }
        nowPlaying.send(command)
        // Update the UI right away; MediaRemote confirms shortly after.
        guard var np = model.nowPlaying else { return }
        let now = Date()
        switch command {
        case .togglePlayPause:
            np.elapsed = np.position(at: now)
            np.timestamp = now
            np.playing.toggle()
        case .seek(let t):
            pendingSeek = (t, now)
            np.elapsed = t
            np.timestamp = now
        case .next, .previous, .openApp:
            return
        }
        withAnimation(.snappy) { model.nowPlaying = np }
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
                if model.claude?.expandable == true { window.setExpanded(true, claude: true) }
                else if model.nowPlaying != nil { window.setExpanded(true) }
            }
        case "leave":
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
            showHUD(HUDState(kind: args.first == "brightness" ? .brightness : .volume, level: level), bump: false)
        case "device":
            let buds = DeviceArtwork.buds(productID: 0x2027).map { AudioDeviceEvent.Visual.buds(left: $0.left, right: $0.right) }
            showDevice(AudioDeviceEvent(name: "AirPods Pro", status: .connected, battery: 76, visual: buds ?? .symbol("airpods.pro")))
        case "charge":
            let kind: ChargeEvent.Kind = switch parts.count > 1 ? parts[1] : "" {
            case "full": .full; case "unplugged": .unplugged; case "low": .low; default: .plugged }
            showCharge(ChargeEvent(kind: kind, percent: kind == .low ? 10 : kind == .full ? 80 : 64))
        case "boop":
            boop()
        case "music":
            // music on|off: a sample track with drawn artwork, nothing real playing needed.
            if parts.count > 1, parts[1] == "on" {
                let song = NowPlaying(title: "Ciudad dormida", artist: "Nadia Ferro", album: "", duration: 198, elapsed: 74,
                                      timestamp: Date(), rate: 1, playing: true, appName: "Music", bundleID: nil,
                                      artwork: SnapshotRenderer.sampleArtwork, accent: Color(red: 1, green: 0.62, blue: 0.42))
                withAnimation(.snappy) { model.nowPlaying = song }
                setMediaVisible(true)
            } else {
                collapseAll()
                setMediaVisible(false)
                withAnimation(.smooth) { model.nowPlaying = nil }
            }
            windows.forEach { $0.refreshHotRect() }
        case "media":
            // media toggle|next|prev: controls whatever is playing, like the player buttons.
            switch parts.count > 1 ? parts[1] : "" {
            case "next": perform(.next)
            case "prev": perform(.previous)
            default: perform(.togglePlayPause)
            }
        case "rec":
            // Fake recording, to test the timer without recording.
            let arg = parts.count > 1 ? parts[1] : "on"
            withAnimation(.snappy) { model.recording = arg == "off" ? nil : ScreenRecording(start: Date(), stoppable: arg != "other") }
            windows.forEach { $0.refreshHotRect() }
        case "stats":
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/brim-build/snapshots").path
            try? "\(CritterDrawing.frames)\n".write(toFile: "\(dir)/frames.txt", atomically: true, encoding: .utf8)
        default:
            break
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
    func greet() { boop() }

    private var boopClicks: [Date] = []
    private var boopHide: DispatchWorkItem?

    /// Clicking the notch with nothing playing. Three clicks within 1.5 s make the face annoyed.
    private func boop() {
        let now = Date()
        boopClicks = boopClicks.filter { now.timeIntervalSince($0) < 1.5 } + [now]
        let annoyed = boopClicks.count >= 3
        if annoyed { boopClicks = [] }
        withAnimation(model.boop == nil ? .snappy : .smooth) { model.boop = BoopEvent(annoyed: annoyed) }
        boopHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.model.boop = nil }
        }
        boopHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (annoyed ? 1.55 : 1.95), execute: work)
    }

    // MARK: - Charging

    private func showCharge(_ event: ChargeEvent) {
        withAnimation(model.charge == nil ? .snappy : .smooth) { model.charge = event }
        chargeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.model.charge = nil }
        }
        chargeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (event.kind == .full ? 3.6 : 3.2), execute: work)
    }

    // MARK: - Audio devices

    private func showDevice(_ event: AudioDeviceEvent) {
        withAnimation(model.device == nil ? .snappy : .smooth) { model.device = event }
        deviceHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.model.device = nil }
        }
        deviceHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deviceDuration, execute: work)
    }

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

    /// 1/16 steps like macOS, 1/64 with Option + Shift.
    private static func stepped(_ value: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let next = (value * steps).rounded() + (up ? 1 : -1)
        return min(1, max(0, next / steps))
    }

    private func handle(_ key: MediaKey, fine: Bool) -> Bool {
        guard prefs.volumeHUD else { return false }
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard SystemVolume.isControllable else { return false }
            var muted = SystemVolume.isMuted
            let old = SystemVolume.volume
            var level = old
            var atLimit = false
            if key == .mute {
                muted.toggle()
                SystemVolume.isMuted = muted
            } else {
                let up = key == .volumeUp
                level = Self.stepped(old, up: up, fine: fine)
                atLimit = level == old && !(up && muted)
                SystemVolume.volume = level
                // Like macOS: volume up unmutes, reaching 0 mutes.
                let shouldMute = !up && level == 0
                if muted != shouldMute { muted = shouldMute; SystemVolume.isMuted = muted }
            }
            showHUD(HUDState(kind: .volume, level: Double(level), muted: muted), bump: atLimit)

        case .brightnessUp, .brightnessDown:
            guard DisplayBrightness.isControllable else { return false }
            let old = DisplayBrightness.brightness
            let level = Self.stepped(old, up: key == .brightnessUp, fine: fine)
            DisplayBrightness.brightness = level
            showHUD(HUDState(kind: .brightness, level: Double(level)), bump: level == old)
        }
        return true
    }

    private func showHUD(_ state: HUDState, bump: Bool) {
        withAnimation(model.hud == nil ? .snappy : .spring(duration: 0.28, bounce: 0)) { model.hud = state }
        if bump { bumpLimit() }
        hudHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.model.hud = nil }
        }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudDuration, execute: work)
    }

    /// Stretches the island a little when a key hits the limit.
    private func bumpLimit() {
        withAnimation(.spring(duration: 0.14, bounce: 0)) { model.stretch = 14 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { self?.model.stretch = 0 }
        }
    }
}
