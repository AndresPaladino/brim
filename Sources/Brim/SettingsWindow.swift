import AppKit
import SwiftUI

enum SettingsTab: CaseIterable {
    case general, alerts, claude

    var title: String {
        switch self {
        case .general: Strings.general
        case .alerts: Strings.alerts
        case .claude: Strings.agentsSection
        }
    }

    var image: NSImage? {
        switch self {
        case .general: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        case .alerts: NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        case .claude: CritterIcon.image
        }
    }

    @MainActor @ViewBuilder
    func view(_ prefs: Preferences) -> some View {
        switch self {
        case .general: GeneralSettings(prefs: prefs)
        case .alerts: AlertSettings(prefs: prefs)
        case .claude: ClaudeSettings(prefs: prefs)
        }
    }
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsWindow.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsForm {
            Section {
                Toggle(Strings.openAtLogin, isOn: $prefs.openAtLogin)
                Picker(Strings.showOn, selection: $prefs.displays) {
                    Text(Strings.allDisplays).tag(DisplayChoice.all)
                    Text(Strings.builtInDisplay).tag(DisplayChoice.builtIn)
                    Text(Strings.externalDisplays).tag(DisplayChoice.external)
                }
            } footer: {
                footnote(Strings.displaysFooter)
            }
            Section {
                Picker(Strings.openPlayer, selection: $prefs.openOnHover) {
                    Text(Strings.onHover).tag(true)
                    Text(Strings.onClick).tag(false)
                }
                .pickerStyle(.segmented)
                LabeledContent(Strings.welcomeScreen) {
                    Button(Strings.showWelcome) {
                        SettingsWindow.shared.close()
                        OnboardingWindow.shared.show()
                    }
                }
            } footer: {
                Text("Brim \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
        }
    }
}

private struct AlertSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsForm {
            Section(Strings.system) {
                toggle($prefs.volumeHUD, Strings.volumeBrightness, Strings.volumeBrightnessDetail)
                toggle($prefs.screenRecording, Strings.screenRecording, Strings.screenRecordingDetail)
            }
            Section(Strings.music) {
                toggle($prefs.mediaAtRest, Strings.musicAtRest, Strings.musicAtRestDetail)
            }
            Section(Strings.battery) {
                toggle($prefs.chargeAlerts, Strings.chargeAlerts, Strings.chargeAlertsDetail)
                toggle($prefs.macLowBattery, Strings.macLowBattery, Strings.macLowBatteryDetail)
            }
            Section(Strings.audio) {
                toggle($prefs.deviceAlerts, Strings.audioDevices, Strings.audioDevicesDetail)
                toggle($prefs.lowBattery, Strings.lowBatteryAlert, Strings.lowBatteryDetail)
            }
        }
    }
}

private struct ClaudeSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsForm {
            Section {
                AgentConnection(title: Strings.claudeSection, badge: CritterIcon.badge, connectedText: Strings.claudeConnected,
                                errorText: Strings.claudeHooksError, isConnected: { ClaudeHooks.isConnected },
                                connect: ClaudeHooks.connect, disconnect: ClaudeHooks.disconnect)
                toggle($prefs.claudeAlerts, Strings.claudeAlerts, Strings.claudeAlertsDetail)
            } footer: {
                footnote(Strings.claudeHooksFooter)
            }
            Section {
                AgentConnection(title: Strings.codexSection, badge: PomponIcon.badge, connectedText: Strings.codexConnected,
                                errorText: Strings.codexHooksError, isConnected: { CodexHooks.isConnected },
                                notInstalled: CodexHooks.isInstalled ? nil : Strings.codexNotInstalled,
                                connect: CodexHooks.connect, disconnect: CodexHooks.disconnect)
                toggle($prefs.codexAlerts, Strings.codexAlerts, Strings.codexAlertsDetail)
            } footer: {
                footnote(Strings.codexHooksFooter)
            }
            Section {
                toggle($prefs.claudeApprove, Strings.claudeApprove, Strings.claudeApproveDetail)
                    .disabled(!prefs.claudeAlerts && !prefs.codexAlerts)
            }
        }
    }
}

/// Badge, name, connection state and the Connect / Disconnect button.
private struct AgentConnection: View {
    let title: String
    let badge: NSImage
    let connectedText: String
    let errorText: String
    let isConnected: () -> Bool
    var notInstalled: String? = nil
    let connect: () throws -> Void
    let disconnect: () throws -> Void
    // Built without Xcode, so no @State macro: State is used directly.
    private let connected = State(initialValue: false)
    private let failed = State(initialValue: false)

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: badge)
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 5) {
                    Circle().fill(connected.wrappedValue ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                    Text(failed.wrappedValue ? errorText
                         : connected.wrappedValue ? connectedText : notInstalled ?? Strings.claudeNotConnected)
                }
                .font(.footnote)
                .foregroundStyle(failed.wrappedValue ? Color.red : .secondary)
            }
            Spacer()
            Button(connected.wrappedValue ? Strings.claudeDisconnect : Strings.claudeConnect) {
                do {
                    if connected.wrappedValue { try disconnect() } else { try connect() }
                    failed.wrappedValue = false
                } catch {
                    failed.wrappedValue = true
                }
                connected.wrappedValue = isConnected()
            }
            .disabled(notInstalled != nil && !connected.wrappedValue)
        }
        .onAppear { connected.wrappedValue = isConnected() }
    }
}

private func toggle(_ isOn: Binding<Bool>, _ title: String, _ detail: String) -> some View {
    Toggle(isOn: isOn) {
        Text(title)
        Text(detail)
    }
}

private func footnote(_ text: String) -> some View {
    Text(text)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// The critter as a template image for the toolbar and as an orange badge.
enum CritterIcon {
    private static let body = ["...BBBBBBBB...", "..BBBBBBBBBB..", "BBBBBBBBBBBBBB", "..BBBBBBBBBB..", "...BBBBBBBB...", "...B.B..B.B...", "...B.B..B.B..."]
    private static let eyes = [(4, 1), (4, 2), (9, 1), (9, 2)]

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
            draw(unit: 1.4, origin: CGPoint(x: 1.2, y: 6.1), body: .black, eyes: .clear)
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let badge: NSImage = NSImage(size: NSSize(width: 26, height: 26), flipped: true) { rect in
        NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        draw(unit: 1.4, origin: CGPoint(x: 3.2, y: 8.1), body: .white, eyes: NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        return true
    }

    private static func draw(unit: CGFloat, origin: CGPoint, body color: NSColor, eyes eyeColor: NSColor) {
        color.setFill()
        for (y, row) in body.enumerated() {
            for (x, c) in row.enumerated() where c == "B" {
                NSRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit, width: unit, height: unit).fill()
            }
        }
        // Eyes are holes in the template and badge-colored in the badge.
        for (x, y) in eyes {
            let r = NSRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit, width: unit, height: unit)
            if eyeColor == .clear { r.fill(using: .clear) } else { eyeColor.setFill(); r.fill(); color.setFill() }
        }
    }
}

/// Toolbar tabs. The window animates to each tab's height.
final class SettingsTabsController: NSTabViewController {
    private let prefs: Preferences

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: AnyView(tab.view(prefs)))
            host.sizingOptions = []
            // The toolbar tab controller titles the window after the selected child.
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = tab.image
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: true)
    }

    /// Resizes to the selected tab, keeping the top edge in place.
    func fitWindow(animated: Bool) {
        guard let window = view.window, selectedTabViewItemIndex >= 0 else { return }
        let tab = SettingsTab.allCases[selectedTabViewItemIndex]
        window.title = tab.title
        // The tab's hosting controller doesn't report a size, so measure the same content separately.
        let height = NSHostingView(rootView: tab.view(prefs)).fittingSize.height
        let size = NSSize(width: SettingsWindow.width, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated)
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let width: CGFloat = 480
    private var window: NSWindow?

    func close() { window?.close() }

    func show() {
        // Onboarding stays on top while it is open.
        if OnboardingWindow.shared.isVisible { OnboardingWindow.shared.focus(); return }
        if window == nil {
            let tabs = SettingsTabsController(prefs: .shared)
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            window = w
            tabs.fitWindow(animated: false)
            w.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// For snapshots.
    static func snapshotWindow(tab: SettingsTab) -> NSWindow {
        let tabs = SettingsTabsController(prefs: .shared)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        tabs.fitWindow(animated: false)
        return w
    }
}

/// The pompom on a lavender tile, for Settings.
enum PomponIcon {
    static let badge: NSImage = NSImage(size: NSSize(width: 26, height: 26), flipped: true) { rect in
        NSColor(red: 143 / 255, green: 157 / 255, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        // Fuzzy white oval with two lavender eyes.
        let body = NSBezierPath()
        let n = 72, cx = 13.0, cy = 14.0
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = 1 + 0.05 * sin(a * 23) + 0.04 * sin(a * 41)
            let e = 2.0 / 2.4, c = cos(a), s = sin(a)
            let p = NSPoint(x: cx + 8.6 * r * copysign(pow(abs(c), e), c), y: cy + 7.2 * r * copysign(pow(abs(s), e), s))
            if i == 0 { body.move(to: p) } else { body.line(to: p) }
        }
        body.close()
        NSColor.white.setFill()
        body.fill()
        NSColor(red: 143 / 255, green: 157 / 255, blue: 1, alpha: 1).setFill()
        for x in [10.0, 16.0] { NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: 12.0, width: 2.2, height: 3.4)).fill() }
        return true
    }
}

