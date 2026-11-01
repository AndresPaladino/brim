import Foundation

/// UI text from Resources/<lang>.lproj/Localizable.strings. Spanish or English, English otherwise.
enum Strings {
    private static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static var connected: String { t("device.connected") }
    static var lowBattery: String { t("device.lowBattery") }
    static var headphones: String { t("device.headphones") }
    static var quit: String { t("menu.quit") }
    static var openAtLogin: String { t("menu.openAtLogin") }
    static var settings: String { t("menu.settings") }
    static var welcomeScreen: String { t("settings.welcome") }
    static var showWelcome: String { t("settings.showWelcome") }
    static var checkForUpdates: String { t("menu.checkForUpdates") }
    static var updates: String { t("settings.updates") }
    static var autoUpdate: String { t("settings.autoUpdate") }
    static var checkNow: String { t("settings.checkNow") }

    // Settings
    static var settingsTitle: String { t("settings.title") }
    static var general: String { t("settings.general") }
    static var openPlayer: String { t("settings.openPlayer") }
    static var onHover: String { t("settings.onHover") }
    static var onClick: String { t("settings.onClick") }
    static var displays: String { t("settings.displays") }
    static var showOn: String { t("settings.showOn") }
    static var allDisplays: String { t("settings.allDisplays") }
    static var builtInDisplay: String { t("settings.builtInDisplay") }
    static var externalDisplays: String { t("settings.externalDisplays") }
    static var displaysFooter: String { t("settings.displaysFooter") }
    static var features: String { t("settings.features") }
    static var volumeBrightness: String { t("settings.volumeBrightness") }
    static var volumeBrightnessDetail: String { t("settings.volumeBrightnessDetail") }
    static var musicAtRest: String { t("settings.musicAtRest") }
    static var musicAtRestDetail: String { t("settings.musicAtRestDetail") }
    static var audioDevices: String { t("settings.audioDevices") }
    static var audioDevicesDetail: String { t("settings.audioDevicesDetail") }
    static var lowBatteryAlert: String { t("settings.lowBattery") }
    static var chargeAlerts: String { t("settings.charge") }
    static var chargeAlertsDetail: String { t("settings.chargeDetail") }
    static var macLowBattery: String { t("settings.macLowBattery") }
    static var macLowBatteryDetail: String { t("settings.macLowBatteryDetail") }
    static var lowBatteryDetail: String { t("settings.lowBatteryDetail") }
    static var alerts: String { t("settings.alerts") }
    static var system: String { t("settings.system") }
    static var music: String { t("settings.music") }
    static var battery: String { t("settings.battery") }
    static var audio: String { t("settings.audio") }
    static var screenRecording: String { t("settings.screenRecording") }
    static var screenRecordingDetail: String { t("settings.screenRecordingDetail") }

    // Onboarding
    static var onbWelcomeTitle: String { t("onb.welcomeTitle") }
    static var onbWelcomeText: String { t("onb.welcomeText") }
    static var onbContinue: String { t("onb.continue") }
    static var onbAccessTitle: String { t("onb.accessTitle") }
    static var onbAccessText: String { t("onb.accessText") }
    static var onbOpenSettings: String { t("onb.openSettings") }
    static var onbBluetoothTitle: String { t("onb.bluetoothTitle") }
    static var onbBluetoothText: String { t("onb.bluetoothText") }
    static var onbAllow: String { t("onb.allow") }
    static var onbConflictTitle: String { t("onb.conflictTitle") }
    static var onbConflictText: String { t("onb.conflictText") }
    static var onbQuitApp: String { t("onb.quitApp") }
    static var onbDoneTitle: String { t("onb.doneTitle") }
    static var onbDoneText: String { t("onb.doneText") }
    static var onbGetStarted: String { t("onb.getStarted") }
    static var onbLater: String { t("onb.later") }
    static var onbWaiting: String { t("onb.waiting") }
    static var onbNotchTitle: String { t("onb.notchTitle") }
    static var onbNotchText: String { t("onb.notchText") }
    static var onbFeaturesTitle: String { t("onb.featuresTitle") }
    static var onbFeaturesText: String { t("onb.featuresText") }
    static var onbAgentsTitle: String { t("onb.agentsTitle") }
    static var onbAgentsText: String { t("onb.agentsText") }
    static var onbRightClick: String { t("onb.rightClick") }

    // Charging
    static var charging: String { t("charge.charging") }
    static var charged: String { t("charge.charged") }
    static var onBattery: String { t("charge.onBattery") }
    static var nowPlaying: String { t("media.nowPlaying") }
    static var previous: String { t("media.previous") }
    static var playPause: String { t("media.playPause") }
    static var next: String { t("media.next") }
    static var audioOutput: String { t("media.audioOutput") }

    /// "80 %" in Spanish, "80%" in English.
    static func percent(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f.string(from: NSNumber(value: Double(value) / 100)) ?? "\(value)%"
    }

    // Claude Code
    static var claudePermissionFor: String { t("claude.permissionFor") }
    static var claudeEdit: String { t("claude.edit") }
    static var claudeCreate: String { t("claude.create") }
    static var claudeOpen: String { t("claude.open") }
    static var claudeSearch: String { t("claude.search") }
    static var claudePlan: String { t("claude.plan") }
    static var claudeLines: String { t("claude.lines") }
    static var claudeNewLines: String { t("claude.newLines") }
    static var claudeDone: String { t("claude.done") }
    static var claudeDoneDetail: String { t("claude.doneDetail") }
    static var claudeError: String { t("claude.error") }
    static var claudeWaiting: String { t("claude.waiting") }
    static var claudeWaitingDetail: String { t("claude.waitingDetail") }
    static var claudeAsks: String { t("claude.asks") }
    static var claudeAnswerIn: String { t("claude.answerIn") }
    static var claudeOtherAnswerIn: String { t("claude.otherAnswerIn") }
    static var claudeSend: String { t("claude.send") }
    static var claudeAnswered: String { t("claude.answered") }
    static var claudeMinutes: String { t("claude.minutes") }
    static var claudeAllow: String { t("claude.allow") }
    static var claudeAllowed: String { t("claude.allowed") }
    static var claudeDenied: String { t("claude.denied") }
    static var claudeDeny: String { t("claude.deny") }
    static var claudeSection: String { t("settings.claude") }
    static var claudeAlerts: String { t("settings.claudeAlerts") }
    static var claudeAlertsDetail: String { t("settings.claudeAlertsDetail") }
    static var claudeApprove: String { t("settings.claudeApprove") }
    static var claudeApproveDetail: String { t("settings.claudeApproveDetail") }
    static var claudeConnected: String { t("settings.claudeConnected") }
    static var claudeNotConnected: String { t("settings.claudeNotConnected") }
    static var claudeConnect: String { t("settings.claudeConnect") }
    static var claudeDisconnect: String { t("settings.claudeDisconnect") }
    static var claudeHooksFooter: String { t("settings.claudeHooksFooter") }
    static var claudeHooksError: String { t("settings.claudeHooksError") }

    // Codex
    static var agentsSection: String { t("settings.agents") }
    static var codexSection: String { t("settings.codex") }
    static var codexEditFiles: String { t("codex.editFiles") }
    static var codexAsks: String { t("codex.asks") }
    static var codexAlerts: String { t("settings.codexAlerts") }
    static var codexAlertsDetail: String { t("settings.codexAlertsDetail") }
    static var codexConnected: String { t("settings.codexConnected") }
    static var codexNotInstalled: String { t("settings.codexNotInstalled") }
    static var codexHooksFooter: String { t("settings.codexHooksFooter") }
    static var codexHooksError: String { t("settings.codexHooksError") }
    static var answerTitle: String { t("settings.answer") }
}
