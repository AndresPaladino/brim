import SwiftUI

/// Decides what the island shows and for how long: HUD, devices, charging, boop and music.
/// It never touches the system; NotchController feeds it events and wires its outputs.
@MainActor
final class IslandPresenter {
    let model: IslandModel
    private let prefs: Preferences
    private let scheduler: Scheduler

    /// What shows changed, so hover areas need recomputing.
    var onLayoutChange: () -> Void = {}
    /// Closes the open players (music stopped). An open Claude drop stays.
    var closePlayer: () -> Void = {}
    /// Sends a command to the Now Playing bridge.
    var sendMedia: (MediaCommand) -> Void = { _ in }
    var openPlayingApp: () -> Void = {}

    static let hudDuration: TimeInterval = 1.6
    static let deviceDuration: TimeInterval = 3.2
    static let chargeDuration: TimeInterval = 3.2
    static let chargeFullDuration: TimeInterval = 3.6
    static let boopDuration: TimeInterval = 1.95
    static let boopAnnoyedDuration: TimeInterval = 1.55
    /// Three clicks within this window make the face annoyed.
    static let boopWindow: TimeInterval = 1.5
    /// After pausing, the artwork stays next to the notch this long.
    static let pausedLinger: TimeInterval = 30
    static let bumpHold: TimeInterval = 0.09
    static let bumpStretch: CGFloat = 14

    private var hudHide: Scheduled?
    private var deviceHide: Scheduled?
    private var chargeHide: Scheduled?
    private var boopHide: Scheduled?
    private var pausedHide: Scheduled?
    private var boopClicks: [Date] = []
    /// After a seek, MediaRemote can report the old position for a moment. Ignore mismatches meanwhile.
    private var pendingSeek: (target: Double, at: Date)?

    init(model: IslandModel, prefs: Preferences? = nil, scheduler: Scheduler? = nil) {
        self.model = model
        self.prefs = prefs ?? .shared
        self.scheduler = scheduler ?? MainScheduler.shared
    }

    // MARK: - Volume and brightness

    /// 1/16 steps like macOS, 1/64 with Option + Shift.
    static func stepped(_ value: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let next = (value * steps).rounded() + (up ? 1 : -1)
        return min(1, max(0, next / steps))
    }

    struct VolumeChange: Equatable {
        var level: Float
        var muted: Bool
        /// The key hit the end of the range: the island stretches a little.
        var atLimit: Bool
        /// Volume to set, or nil to leave it.
        var setVolume: Float?
        /// Mute state to set, or nil to leave it.
        var setMuted: Bool?
    }

    /// What a volume key does. Like macOS: volume up unmutes, reaching 0 mutes.
    static func volumeChange(_ key: MediaKey, volume old: Float, muted: Bool, fine: Bool) -> VolumeChange {
        if key == .mute { return VolumeChange(level: old, muted: !muted, atLimit: false, setVolume: nil, setMuted: !muted) }
        let up = key == .volumeUp
        let level = stepped(old, up: up, fine: fine)
        let shouldMute = !up && level == 0
        return VolumeChange(level: level, muted: shouldMute, atLimit: level == old && !(up && muted),
                            setVolume: level, setMuted: muted != shouldMute ? shouldMute : nil)
    }

    func showHUD(_ state: HUDState, bump: Bool) {
        withAnimation(model.hud == nil ? .snappy : .spring(duration: 0.28, bounce: 0)) { model.hud = state }
        if bump { bumpLimit() }
        hudHide?.cancel()
        hudHide = scheduler.after(Self.hudDuration) { [weak self] in
            withAnimation(.smooth) { self?.model.hud = nil }
        }
    }

    /// Stretches the island a little when a key hits the limit.
    private func bumpLimit() {
        withAnimation(.spring(duration: 0.14, bounce: 0)) { model.stretch = Self.bumpStretch }
        scheduler.after(Self.bumpHold) { [weak self] in
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { self?.model.stretch = 0 }
        }
    }

    // MARK: - Alerts

    func showDevice(_ event: AudioDeviceEvent) {
        withAnimation(model.device == nil ? .snappy : .smooth) { model.device = event }
        deviceHide?.cancel()
        deviceHide = scheduler.after(Self.deviceDuration) { [weak self] in
            withAnimation(.smooth) { self?.model.device = nil }
        }
    }

    func showCharge(_ event: ChargeEvent) {
        withAnimation(model.charge == nil ? .snappy : .smooth) { model.charge = event }
        chargeHide?.cancel()
        chargeHide = scheduler.after(event.kind == .full ? Self.chargeFullDuration : Self.chargeDuration) { [weak self] in
            withAnimation(.smooth) { self?.model.charge = nil }
        }
    }

    /// The charge alert for a power event, or nil when the settings turn it off.
    static func chargeEvent(for event: PowerMonitor.Event, chargeAlerts: Bool, macLowBattery: Bool) -> ChargeEvent? {
        switch event {
        case .plugged(let pct, let full): chargeAlerts ? ChargeEvent(kind: full ? .charged : .plugged, percent: pct) : nil
        case .unplugged(let pct): chargeAlerts ? ChargeEvent(kind: .unplugged, percent: pct) : nil
        case .full(let pct): chargeAlerts ? ChargeEvent(kind: .full, percent: pct) : nil
        case .low(let pct): macLowBattery ? ChargeEvent(kind: .low, percent: pct) : nil
        }
    }

    func power(_ event: PowerMonitor.Event) {
        if let charge = Self.chargeEvent(for: event, chargeAlerts: prefs.chargeAlerts, macLowBattery: prefs.macLowBattery) { showCharge(charge) }
    }

    /// Clicking the notch with nothing playing. Three clicks within 1.5 s make the face annoyed.
    func boop() {
        let now = scheduler.now
        boopClicks = boopClicks.filter { now.timeIntervalSince($0) < Self.boopWindow } + [now]
        let annoyed = boopClicks.count >= 3
        if annoyed { boopClicks = [] }
        withAnimation(model.boop == nil ? .snappy : .smooth) { model.boop = BoopEvent(annoyed: annoyed) }
        boopHide?.cancel()
        boopHide = scheduler.after(annoyed ? Self.boopAnnoyedDuration : Self.boopDuration) { [weak self] in
            withAnimation(.smooth) { self?.model.boop = nil }
        }
    }

    // MARK: - Now Playing

    /// Returns true when a new track appeared (a good moment to check headphone battery).
    @discardableResult
    func nowPlayingChanged(_ incoming: NowPlaying?) -> Bool {
        let np = correctingStaleSeek(incoming)
        let old = model.nowPlaying
        let appearing = old == nil || old?.trackID != np?.trackID
        withAnimation(appearing ? .snappy : .smooth) { model.nowPlaying = np }
        if np == nil { closePlayer() }
        // On displays without a notch the hover area depends on whether something is playing.
        if (old == nil) != (np == nil) { onLayoutChange() }
        updateMediaVisibility()
        return appearing && np != nil
    }

    func updateMediaVisibility() {
        let shown = prefs.mediaAtRest && model.nowPlaying != nil
        guard shown, model.nowPlaying?.playing == false else {
            pausedHide?.cancel(); pausedHide = nil
            setMediaVisible(shown)
            return
        }
        // The bridge keeps sending updates while paused (artwork, seek): they don't restart the linger.
        guard model.mediaVisible, pausedHide == nil else { return }
        pausedHide = scheduler.after(Self.pausedLinger) { [weak self] in
            self?.pausedHide = nil
            self?.setMediaVisible(false)
        }
    }

    func setMediaVisible(_ visible: Bool) {
        guard model.mediaVisible != visible else { return }
        withAnimation(visible ? .snappy : .smooth) { model.mediaVisible = visible }
        onLayoutChange()
    }

    private func correctingStaleSeek(_ incoming: NowPlaying?) -> NowPlaying? {
        guard var np = incoming, let seek = pendingSeek else { return incoming }
        let now = scheduler.now
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

    func perform(_ command: MediaCommand) {
        if case .openApp = command { openPlayingApp(); return }
        sendMedia(command)
        // Update the UI right away; MediaRemote confirms shortly after.
        guard var np = model.nowPlaying else { return }
        let now = scheduler.now
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
}
