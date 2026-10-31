import AppKit

@main
enum BrimApp {
    @MainActor static func main() {
        if SnapshotRenderer.runIfRequested() { return }
        // Writing to the Now Playing bridge right after it died would raise SIGPIPE and kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    /// Opening Brim.app again shows Settings. On displays without a notch it is the only way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        OnboardingWindow.shared.onFinished = { [weak self] in self?.controller?.greet() }
        if OnboardingWindow.shouldShow { OnboardingWindow.shared.show() }
        LoginItem.enableOnFirstLaunch()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.reposition() }
        }
    }
}
