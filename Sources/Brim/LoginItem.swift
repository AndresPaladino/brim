import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.andrespaladino.brim", category: "login")

@MainActor
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Could not change the login item: \(error.localizedDescription)")
        }
    }

    /// On by default the first time the app runs from /Applications.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: configuredKey),
              Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: configuredKey)
        setEnabled(true)
    }
}

@MainActor
final class IslandMenu: NSObject {
    static let shared = IslandMenu()
    var onOpenSettings: (() -> Void)?

    func make() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: Strings.settings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let updates = NSMenuItem(title: Strings.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let login = NSMenuItem(title: Strings.openAtLogin, action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: Strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func toggleLogin() { Preferences.shared.openAtLogin = !LoginItem.isEnabled }
    @objc private func checkForUpdates() {
        onOpenSettings?()
        Updater.shared.checkForUpdates()
    }
    @objc private func openSettings() {
        onOpenSettings?()
        SettingsWindow.shared.show()
    }
}
