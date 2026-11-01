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
        // One Brim at a time: a second one would draw a second island and tap the keys twice.
        // Opening it again goes to the running one, which shows Settings (see above).
        if let other = Self.otherInstance() {
            NSWorkspace.shared.openApplication(at: other.bundleURL ?? Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        controller = NotchController()
        OnboardingWindow.shared.onFinished = { [weak self] in self?.controller?.greet() }
        if OnboardingWindow.shouldShow { OnboardingWindow.shared.show() }
        LoginItem.enableOnFirstLaunch()
        Updater.shared.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.reposition() }
        }
    }

    private static func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me && !$0.isTerminated }
    }
}
