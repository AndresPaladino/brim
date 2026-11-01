import AppKit
import Sparkle

/// Updates through Sparkle. Checks docs/appcast.xml on the website once a day and offers each new
/// release in Sparkle's window, or installs it on its own when automatic updates are on.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private init() {}

    /// Starts the daily checks.
    func start() { _ = controller }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Downloads updates in the background and installs them when Brim quits or relaunches.
    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}
