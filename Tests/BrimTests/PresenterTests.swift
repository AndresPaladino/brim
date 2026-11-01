import Testing
import Foundation
@testable import Brim

/// Timers and decisions in IslandPresenter, on a manual clock.
@MainActor
@Suite struct PresenterTests {
    let clock = ManualScheduler()
    let model = IslandModel()

    func presenter(_ configure: (Preferences) -> Void = { _ in }) -> IslandPresenter {
        IslandPresenter(model: model, prefs: makePreferences(configure), scheduler: clock)
    }

    // MARK: Volume steps

    @Test func steps() {
        #expect(IslandPresenter.stepped(0.5, up: true, fine: false) == Float(9) / 16)
        #expect(IslandPresenter.stepped(0.5, up: false, fine: false) == Float(7) / 16)
        #expect(IslandPresenter.stepped(0.5, up: true, fine: true) == Float(33) / 64)
        #expect(IslandPresenter.stepped(1, up: true, fine: false) == 1)
        #expect(IslandPresenter.stepped(0, up: false, fine: false) == 0)
        // Off-grid values snap to the nearest step first (another app set 0.51).
        #expect(IslandPresenter.stepped(0.51, up: true, fine: false) == Float(9) / 16)
        #expect(IslandPresenter.stepped(0.03, up: false, fine: false) == 0)
    }

    @Test func sixteenPressesGoFromZeroToFull() {
        var v: Float = 0
        for _ in 0..<16 { v = IslandPresenter.stepped(v, up: true, fine: false) }
        #expect(v == 1)
        for _ in 0..<64 { v = IslandPresenter.stepped(v, up: false, fine: true) }
        #expect(v == 0)
    }

    @Test(arguments: stride(from: Float(0), through: 1, by: 0.01).map { $0 })
    func stepsStayInRange(value: Float) {
        for fine in [false, true] {
            for up in [false, true] {
                let s = IslandPresenter.stepped(value, up: up, fine: fine)
                #expect((0...1).contains(s))
                if up { #expect(s >= value - 1 / 128) } else { #expect(s <= value + 1 / 128) }
            }
        }
    }

    @Test func volumeKeys() {
        typealias P = IslandPresenter
        // Up from the middle: no mute change.
        var c = P.volumeChange(.volumeUp, volume: 0.5, muted: false, fine: false)
        #expect(c.level == 9 / 16 && !c.muted && !c.atLimit && c.setVolume == 9 / 16 && c.setMuted == nil)
        // Up while muted unmutes.
        c = P.volumeChange(.volumeUp, volume: 0.5, muted: true, fine: false)
        #expect(!c.muted && c.setMuted == false)
        // Up at full: limit bump, but not when it also unmutes.
        #expect(P.volumeChange(.volumeUp, volume: 1, muted: false, fine: false).atLimit)
        #expect(!P.volumeChange(.volumeUp, volume: 1, muted: true, fine: false).atLimit)
        // Down to zero mutes.
        c = P.volumeChange(.volumeDown, volume: 1 / 16, muted: false, fine: false)
        #expect(c.level == 0 && c.muted && c.setMuted == true && !c.atLimit)
        // Down at zero: limit bump, stays muted, nothing to change.
        c = P.volumeChange(.volumeDown, volume: 0, muted: true, fine: false)
        #expect(c.atLimit && c.muted && c.setMuted == nil)
        // Mute toggles without touching the level.
        c = P.volumeChange(.mute, volume: 0.3, muted: false, fine: false)
        #expect(c.muted && c.setMuted == true && c.setVolume == nil && c.level == 0.3)
        c = P.volumeChange(.mute, volume: 0.3, muted: true, fine: false)
        #expect(!c.muted && c.setMuted == false)
    }

    // MARK: Alert timers

    @Test func hudHidesAfterItsDuration() {
        let p = presenter()
        p.showHUD(HUDState(kind: .volume, level: 0.5), bump: false)
        clock.advance(by: 1.59)
        #expect(model.hud != nil)
        clock.advance(by: 0.02)
        #expect(model.hud == nil)
    }

    @Test func eachKeyPressRestartsTheHUDTimer() {
        let p = presenter()
        for i in 0..<10 {
            p.showHUD(HUDState(kind: .volume, level: Double(i) / 10), bump: false)
            clock.advance(by: 1.0)
            #expect(model.hud?.level == Double(i) / 10)
        }
        clock.advance(by: 0.61)
        #expect(model.hud == nil)
        #expect(clock.pending == 0)
    }

    @Test func bumpStretchesAndComesBack() {
        let p = presenter()
        p.showHUD(HUDState(kind: .volume, level: 1), bump: true)
        #expect(model.stretch == IslandPresenter.bumpStretch)
        clock.advance(by: 0.1)
        #expect(model.stretch == 0)
    }

    @Test func deviceAndChargeDurations() {
        let p = presenter()
        p.showDevice(AudioDeviceEvent(name: "AirPods", status: .connected, battery: 70, visual: .symbol("airpods")))
        clock.advance(by: 3.19); #expect(model.device != nil)
        clock.advance(by: 0.02); #expect(model.device == nil)

        p.showCharge(ChargeEvent(kind: .plugged, percent: 50))
        clock.advance(by: 3.19); #expect(model.charge != nil)
        clock.advance(by: 0.02); #expect(model.charge == nil)

        p.showCharge(ChargeEvent(kind: .full, percent: 80))
        clock.advance(by: 3.59); #expect(model.charge != nil)
        clock.advance(by: 0.02); #expect(model.charge == nil)
    }

    @Test func aNewChargeEventReplacesTheOldOneAndItsTimer() {
        let p = presenter()
        p.showCharge(ChargeEvent(kind: .plugged, percent: 50))
        clock.advance(by: 3)
        p.showCharge(ChargeEvent(kind: .full, percent: 80))
        clock.advance(by: 0.5) // the first timer would have fired here
        #expect(model.charge?.kind == .full)
        clock.advance(by: 3.2)
        #expect(model.charge == nil)
    }

    @Test func boopAndAnnoyedBoop() {
        let p = presenter()
        p.boop()
        #expect(model.boop?.annoyed == false)
        clock.advance(by: 0.5); p.boop()
        clock.advance(by: 0.5); p.boop()
        #expect(model.boop?.annoyed == true)
        clock.advance(by: 1.54); #expect(model.boop != nil)
        clock.advance(by: 0.02); #expect(model.boop == nil)
        // The count restarts after the annoyed face.
        p.boop()
        #expect(model.boop?.annoyed == false)
    }

    @Test func slowClicksNeverAnnoy() {
        let p = presenter()
        for _ in 0..<10 {
            p.boop()
            #expect(model.boop?.annoyed == false)
            clock.advance(by: 0.76) // three clicks span 1.52 s > 1.5 s
        }
        clock.advance(by: 2)
        #expect(model.boop == nil)
    }

    // MARK: Power

    @Test func chargeEventsFollowSettings() {
        typealias P = IslandPresenter
        #expect(P.chargeEvent(for: .plugged(percent: 40, alreadyFull: false), chargeAlerts: true, macLowBattery: true)?.kind == .plugged)
        #expect(P.chargeEvent(for: .plugged(percent: 100, alreadyFull: true), chargeAlerts: true, macLowBattery: true)?.kind == .charged)
        #expect(P.chargeEvent(for: .unplugged(percent: 40), chargeAlerts: true, macLowBattery: true)?.kind == .unplugged)
        #expect(P.chargeEvent(for: .full(percent: 80), chargeAlerts: true, macLowBattery: true)?.kind == .full)
        #expect(P.chargeEvent(for: .plugged(percent: 40, alreadyFull: false), chargeAlerts: false, macLowBattery: true) == nil)
        // Low battery has its own switch, independent of charge alerts.
        #expect(P.chargeEvent(for: .low(percent: 10), chargeAlerts: false, macLowBattery: true)?.kind == .low)
        #expect(P.chargeEvent(for: .low(percent: 10), chargeAlerts: true, macLowBattery: false) == nil)
    }

    // MARK: Music

    @Test func artworkLingersThirtySecondsAfterPausing() {
        let p = presenter()
        p.nowPlayingChanged(track(at: clock.now))
        #expect(model.mediaVisible)
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        clock.advance(by: 29.9); #expect(model.mediaVisible)
        clock.advance(by: 0.2); #expect(!model.mediaVisible)
        #expect(model.nowPlaying != nil) // still loaded, just hidden
    }

    @Test func resumingCancelsTheLinger() {
        let p = presenter()
        p.nowPlayingChanged(track(at: clock.now))
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        clock.advance(by: 20)
        p.nowPlayingChanged(track(at: clock.now))
        clock.advance(by: 60)
        #expect(model.mediaVisible)
    }

    /// While paused, the bridge keeps sending updates (artwork, seek). Each one used to restart the 30 s
    /// timer, so the artwork could stay forever if the player kept talking.
    @Test func pausedUpdatesShouldNotExtendTheLinger() {
        let p = presenter()
        p.nowPlayingChanged(track(at: clock.now))
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        for _ in 0..<5 {
            clock.advance(by: 10)
            p.nowPlayingChanged(track(playing: false, at: clock.now))
        }
        #expect(!model.mediaVisible, "50 s after pausing the artwork is still visible")
    }

    /// Playing again cancels the linger; pausing again starts a fresh one.
    @Test func resumingResetsTheLinger() {
        let p = presenter()
        p.nowPlayingChanged(track(at: clock.now))
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        clock.advance(by: 20)
        p.nowPlayingChanged(track(at: clock.now))
        clock.advance(by: 20)
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        clock.advance(by: 20)
        #expect(model.mediaVisible)
        clock.advance(by: 11)
        #expect(!model.mediaVisible)
        #expect(clock.pending == 0)
    }

    @Test func mediaAtRestOffHidesTheEars() {
        let p = presenter { $0.mediaAtRest = false }
        p.nowPlayingChanged(track(at: clock.now))
        #expect(!model.mediaVisible)
        #expect(model.nowPlaying != nil)
    }

    @Test func stoppingMusicCollapsesAndReportsLayout() {
        let p = presenter()
        var collapsed = 0, layouts = 0
        p.closePlayer = { collapsed += 1 }
        p.onLayoutChange = { layouts += 1 }
        #expect(p.nowPlayingChanged(track(at: clock.now)))       // new track
        #expect(!p.nowPlayingChanged(track(elapsed: 20, at: clock.now))) // same track
        #expect(p.nowPlayingChanged(track("Other", at: clock.now)))  // track change
        p.nowPlayingChanged(nil)
        #expect(collapsed == 1)
        #expect(model.nowPlaying == nil && !model.mediaVisible)
        #expect(layouts >= 2)
    }

    @Test func playPauseIsOptimistic() {
        let p = presenter()
        var sent: [String] = []
        p.sendMedia = { sent.append("\($0)") }
        p.nowPlayingChanged(track(elapsed: 10, at: clock.now))
        clock.advance(by: 5)
        p.perform(.togglePlayPause)
        #expect(model.nowPlaying?.playing == false)
        #expect(abs((model.nowPlaying?.elapsed ?? 0) - 15) < 0.001)
        #expect(sent == ["togglePlayPause"])
        p.perform(.next)
        #expect(model.nowPlaying?.title == "Song") // waits for the bridge
        var opened = false
        p.openPlayingApp = { opened = true }
        p.perform(.openApp)
        #expect(opened && sent.count == 2)
    }

    @Test func staleSeekIsCorrected() {
        let p = presenter()
        p.nowPlayingChanged(track(elapsed: 10, at: clock.now))
        p.perform(.seek(120))
        #expect(model.nowPlaying?.elapsed == 120)
        // MediaRemote briefly reports the old position: ignored.
        clock.advance(by: 0.3)
        p.nowPlayingChanged(track(elapsed: 10.3, at: clock.now))
        #expect(abs((model.nowPlaying?.position(at: clock.now) ?? 0) - 120.3) < 0.01)
        // Then the right one: accepted, and the correction ends.
        clock.advance(by: 0.3)
        p.nowPlayingChanged(track(elapsed: 120.6, at: clock.now))
        #expect(abs((model.nowPlaying?.elapsed ?? 0) - 120.6) < 0.01)
        clock.advance(by: 0.3)
        p.nowPlayingChanged(track(elapsed: 50, at: clock.now)) // a real seek from the app
        #expect(model.nowPlaying?.elapsed == 50)
    }

    @Test func staleSeekCorrectionExpires() {
        let p = presenter()
        p.nowPlayingChanged(track(elapsed: 10, at: clock.now))
        p.perform(.seek(120))
        clock.advance(by: 2.5)
        p.nowPlayingChanged(track(elapsed: 12.5, at: clock.now)) // after 2 s the bridge wins
        #expect(model.nowPlaying?.elapsed == 12.5)
    }

    @Test func noTimersLeftAfterEverythingSettles() {
        let p = presenter()
        p.showHUD(HUDState(kind: .volume, level: 1), bump: true)
        p.showDevice(AudioDeviceEvent(name: "x", status: .connected, battery: nil, visual: .symbol("x")))
        p.showCharge(ChargeEvent(kind: .low, percent: 9))
        p.boop()
        p.nowPlayingChanged(track(at: clock.now))
        p.nowPlayingChanged(track(playing: false, at: clock.now))
        clock.drain()
        #expect(clock.pending == 0)
        #expect(model.hud == nil && model.device == nil && model.charge == nil && model.boop == nil && !model.mediaVisible && model.stretch == 0)
    }
}
