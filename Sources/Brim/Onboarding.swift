import AppKit
import SwiftUI
import CoreBluetooth

/// Onboarding, one step at a time. Granted permissions are skipped, and each permission step moves on
/// by itself when macOS reports it granted. After the permissions come a few of the settings, so the
/// features are found on day one instead of behind the notch's right-click menu.
@MainActor
final class OnboardingModel: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Step: Equatable {
        case welcome, accessibility, bluetooth, conflict(String), notch, features, agents, done
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var index = 0
    @Published private(set) var waiting = false
    /// Shows a green checkmark for a moment before moving on.
    @Published private(set) var granted = false
    var onFinish: (() -> Void)?

    private var bluetooth: CBCentralManager?
    private var axObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    /// Other notch apps that also take over the volume keys.
    private static let conflicting = ["MediaMate", "NotchNook", "boring.notch", "Alcove", "DynamicLake", "Atoll"]

    var step: Step { steps.indices.contains(index) ? steps[index] : .done }

    static var needsBluetooth: Bool { CBManager.authorization == .notDetermined }

    static var hasAgents: Bool { ClaudeHooks.isInstalled || CodexHooks.isInstalled }

    static func conflictingApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let name = app.localizedName else { return false }
            return conflicting.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    override init() {
        super.init()
        var s: [Step] = [.welcome]
        if !AXIsProcessTrusted() { s.append(.accessibility) }
        if Self.needsBluetooth { s.append(.bluetooth) }
        if let app = Self.conflictingApp()?.localizedName { s.append(.conflict(app)) }
        s += [.notch, .features]
        if Self.hasAgents { s.append(.agents) }
        s.append(.done)
        steps = s
    }

    private(set) var isSnapshot = false

    /// For snapshots: one step, no prompts.
    init(snapshot step: Step) {
        super.init()
        isSnapshot = true
        steps = [.welcome, .accessibility, .bluetooth, .conflict("MediaMate"), .notch, .features, .agents, .done]
        index = steps.firstIndex(of: step) ?? 0
    }

    func primary() {
        switch step {
        case .welcome: next()
        case .accessibility:
            waiting = true
            // The system prompt also adds Brim to the Accessibility list.
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            watchAccessibility()
        case .bluetooth:
            waiting = true
            bluetooth = CBCentralManager(delegate: self, queue: .main)
        case .conflict(let name):
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.terminate()
            next()
        case .notch, .features, .agents: next()
        case .done:
            onFinish?()
        }
    }

    func later() { next() }

    private func next() {
        stopWatching()
        waiting = false
        granted = false
        withAnimation(.snappy) { index = min(index + 1, steps.count - 1) }
    }

    private func markGranted() {
        stopWatching()
        withAnimation(.snappy) { granted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.next() }
    }

    /// Accessibility changes come as a notification. While this window is open it also checks once a
    /// second, because the notification can arrive late.
    private func watchAccessibility() {
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.checkAccessibility() } }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
    }

    private func checkAccessibility() {
        if step == .accessibility, AXIsProcessTrusted() { markGranted() }
    }

    /// The window closed before the end: nothing keeps checking in the background.
    func stop() {
        stopWatching()
        bluetooth?.delegate = nil
        bluetooth = nil
    }

    private func stopWatching() {
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard step == .bluetooth else { return }
            switch CBManager.authorization {
            case .allowedAlways: markGranted()
            case .denied, .restricted: next()
            default: break
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var prefs: Preferences = .shared

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                page(model.step)
                    .id(model.index)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(height: 290)
            .clipped()

            HStack(spacing: 6) {
                ForEach(model.steps.indices, id: \.self) { i in
                    Circle().fill(i == model.index ? Color.primary : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }

            VStack(spacing: 8) {
                Button(action: model.primary) {
                    Text(model.waiting ? Strings.onbWaiting : primaryTitle)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.waiting)
                .keyboardShortcut(.defaultAction)

                Button(Strings.onbLater, action: model.later)
                    .buttonStyle(.link)
                    .opacity(isPermission ? 1 : 0)
                    .disabled(!isPermission)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 26)
        .frame(width: 480)
    }

    private var isPermission: Bool { model.step == .accessibility || model.step == .bluetooth }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: Strings.onbContinue
        case .accessibility: Strings.onbOpenSettings
        case .bluetooth: Strings.onbAllow
        case .conflict(let name): String(format: Strings.onbQuitApp, name)
        case .notch, .features, .agents: Strings.onbContinue
        case .done: Strings.onbGetStarted
        }
    }

    @ViewBuilder
    private func page(_ step: OnboardingModel.Step) -> some View {
        VStack(spacing: 14) {
            switch step {
            case .welcome:
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                texts(Strings.onbWelcomeTitle, Strings.onbWelcomeText)
            case .accessibility:
                badge("accessibility", .blue)
                texts(Strings.onbAccessTitle, Strings.onbAccessText)
            case .bluetooth:
                badge("headphones", .blue)
                texts(Strings.onbBluetoothTitle, Strings.onbBluetoothText)
            case .conflict(let name):
                badge("exclamationmark.triangle.fill", .orange)
                texts(String(format: Strings.onbConflictTitle, name), Strings.onbConflictText)
            case .notch:
                texts(Strings.onbNotchTitle, Strings.onbNotchText)
                HStack(spacing: 12) {
                    openCard(hover: true)
                    openCard(hover: false)
                }
                .padding(.top, 6)
            case .features:
                texts(Strings.onbFeaturesTitle, Strings.onbFeaturesText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    feature($prefs.volumeHUD, "speaker.wave.2.fill", Strings.volumeBrightness)
                    feature($prefs.mediaAtRest, "music.note", Strings.musicAtRest)
                    feature($prefs.screenRecording, "record.circle", Strings.screenRecording)
                    feature($prefs.deviceAlerts, "headphones", Strings.audioDevices)
                    feature($prefs.chargeAlerts, "bolt.fill", Strings.chargeAlerts)
                    feature($prefs.macLowBattery, "battery.25percent", Strings.macLowBattery)
                }
                .padding(.top, 6)
            case .agents:
                HStack(spacing: -10) {
                    agentBadge(CritterIcon.badge).zIndex(1)
                    agentBadge(PomponIcon.badge).rotationEffect(.degrees(8))
                }
                texts(Strings.onbAgentsTitle, Strings.onbAgentsText)
                VStack(spacing: 0) {
                    if ClaudeHooks.isInstalled || model.isSnapshot {
                        AgentConnection(title: Strings.claudeSection, badge: CritterIcon.badge, connectedText: Strings.claudeConnected,
                                        errorText: Strings.claudeHooksError, isConnected: { ClaudeHooks.isConnected },
                                        connect: ClaudeHooks.connect, disconnect: ClaudeHooks.disconnect)
                            .padding(.vertical, 9)
                    }
                    if ClaudeHooks.isInstalled && CodexHooks.isInstalled || model.isSnapshot { Divider() }
                    if CodexHooks.isInstalled || model.isSnapshot {
                        AgentConnection(title: Strings.codexSection, badge: PomponIcon.badge, connectedText: Strings.codexConnected,
                                        errorText: Strings.codexHooksError, isConnected: { CodexHooks.isConnected },
                                        connect: CodexHooks.connect, disconnect: CodexHooks.disconnect)
                            .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .done:
                badge("checkmark", .green)
                texts(Strings.onbDoneTitle, Strings.onbDoneText)
                rightClickHint.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        let done = model.granted
        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(done ? Color.green : color)
            .frame(width: 76, height: 76)
            .overlay {
                Image(systemName: done ? "checkmark" : symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(done ? 1.06 : 1)
            .animation(.spring(duration: 0.45, bounce: 0.45), value: done)
    }

    /// One way to open the notch, as a mini notch with a cursor over it.
    private func openCard(hover: Bool) -> some View {
        let selected = prefs.openOnHover == hover
        return Button {
            withAnimation(.snappy) { prefs.openOnHover = hover }
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 74)
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                        .fill(.black)
                        .frame(width: 64, height: 18)
                    Image(systemName: hover ? "cursorarrow" : "cursorarrow.click.2")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.primary)
                        .offset(x: hover ? 14 : 8, y: hover ? 22 : 16)
                        .symbolEffect(.bounce, value: selected)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(hover ? Strings.onHover : Strings.onClick)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A feature tile that turns on and off.
    private func feature(_ isOn: Binding<Bool>, _ symbol: String, _ title: String) -> some View {
        let on = isOn.wrappedValue
        return Button {
            withAnimation(.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            VStack(spacing: 7) {
                Circle()
                    .fill(on ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? Color.white : Color.secondary)
                    }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func agentBadge(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable().interpolation(.high)
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    /// The notch with its right-click menu, so Settings can be found later.
    private var rightClickHint: some View {
        HStack(spacing: 14) {
            // A corner of the screen: the notch on top, the menu opening where the cursor clicked.
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.06)
                UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7, style: .continuous)
                    .fill(.black)
                    .frame(width: 50, height: 13)
                    .offset(x: 25)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.settings)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    Text(Strings.quit).padding(.horizontal, 6).padding(.vertical, 2)
                }
                .font(.system(size: 9))
                .padding(3)
                .frame(width: 84)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(color: .black.opacity(0.2), radius: 3, y: 1))
                .offset(x: 44, y: 14)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .medium))
                    .shadow(color: .white, radius: 1)
                    .offset(x: 39, y: 6)
            }
            .frame(width: 132, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(Strings.onbRightClick)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 200, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func texts(_ title: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
    }
}

@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private static let doneKey = "onboardingDone"
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var closeObserver: NSObjectProtocol?

    /// First launch without Accessibility, or forced with --onboarding.
    static var shouldShow: Bool {
        CommandLine.arguments.contains("--onboarding")
            || (!UserDefaults.standard.bool(forKey: doneKey) && !AXIsProcessTrusted())
    }

    var onFinished: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func show() {
        if isVisible { focus(); return }
        let model = OnboardingModel()
        self.model = model
        model.onFinish = { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            self?.window?.close()
            self?.window = nil
            self?.model = nil
            self?.onFinished?()
        }
        let host = NSHostingView(rootView: OnboardingView(model: model))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        window = w
        // Closed from the title bar on the Accessibility step, the once-a-second check kept running.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func closed() {
        model?.stop()
        model = nil
        window = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}
