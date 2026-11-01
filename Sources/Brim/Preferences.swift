import Foundation

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    var onDisplaysChange: (() -> Void)?
    var onMediaAtRestChange: (() -> Void)?

    @Published var displays: DisplayChoice {
        didSet { defaults.set(displays.rawValue, forKey: "displays"); onDisplaysChange?() }
    }
    /// true: the notch opens on hover; false: on click.
    @Published var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    @Published var volumeHUD: Bool { didSet { defaults.set(volumeHUD, forKey: "volumeHUD") } }
    @Published var mediaAtRest: Bool {
        didSet { defaults.set(mediaAtRest, forKey: "mediaAtRest"); onMediaAtRestChange?() }
    }
    @Published var deviceAlerts: Bool { didSet { defaults.set(deviceAlerts, forKey: "deviceAlerts") } }
    @Published var lowBattery: Bool { didSet { defaults.set(lowBattery, forKey: "lowBattery") } }
    @Published var chargeAlerts: Bool { didSet { defaults.set(chargeAlerts, forKey: "chargeAlerts") } }
    @Published var macLowBattery: Bool { didSet { defaults.set(macLowBattery, forKey: "macLowBattery") } }
    @Published var screenRecording: Bool {
        didSet { defaults.set(screenRecording, forKey: "screenRecording"); onScreenRecordingChange?() }
    }
    var onScreenRecordingChange: (() -> Void)?
    @Published var claudeAlerts: Bool { didSet { defaults.set(claudeAlerts, forKey: "claudeAlerts"); onClaudeChange?() } }
    /// Answer Claude Code and Codex permissions, and Claude's questions, from the notch.
    @Published var claudeApprove: Bool { didSet { defaults.set(claudeApprove, forKey: "claudeApprove") } }
    @Published var codexAlerts: Bool { didSet { defaults.set(codexAlerts, forKey: "codexAlerts"); onClaudeChange?() } }
    var onClaudeChange: (() -> Void)?
    /// Mirrors the actual login item state.
    @Published var openAtLogin: Bool {
        didSet {
            guard openAtLogin != LoginItem.isEnabled else { return }
            LoginItem.setEnabled(openAtLogin)
            if openAtLogin != LoginItem.isEnabled { openAtLogin = LoginItem.isEnabled }
        }
    }

    /// Tests pass their own suite; the app always uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "displays": DisplayChoice.all.rawValue, "openOnHover": true, "volumeHUD": true,
            "mediaAtRest": true, "deviceAlerts": true, "lowBattery": true, "chargeAlerts": true, "macLowBattery": true, "screenRecording": true,
            "claudeAlerts": true, "claudeApprove": true, "codexAlerts": true,
        ])
        displays = DisplayChoice(rawValue: defaults.string(forKey: "displays") ?? "") ?? .all
        openOnHover = defaults.bool(forKey: "openOnHover")
        volumeHUD = defaults.bool(forKey: "volumeHUD")
        mediaAtRest = defaults.bool(forKey: "mediaAtRest")
        deviceAlerts = defaults.bool(forKey: "deviceAlerts")
        lowBattery = defaults.bool(forKey: "lowBattery")
        chargeAlerts = defaults.bool(forKey: "chargeAlerts")
        macLowBattery = defaults.bool(forKey: "macLowBattery")
        screenRecording = defaults.bool(forKey: "screenRecording")
        claudeAlerts = defaults.bool(forKey: "claudeAlerts")
        claudeApprove = defaults.bool(forKey: "claudeApprove")
        codexAlerts = defaults.bool(forKey: "codexAlerts")
        openAtLogin = LoginItem.isEnabled
    }
}
