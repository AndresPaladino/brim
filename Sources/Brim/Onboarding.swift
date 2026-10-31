import AppKit
import SwiftUI
import CoreBluetooth

/// Onboarding, one step at a time. Granted permissions are skipped, and each permission step moves on
/// by itself when macOS reports it granted.
@MainActor
final class OnboardingModel: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Step: Equatable {
        case welcome, accessibility, bluetooth, conflict(String), done
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
        s.append(.done)
        steps = s
    }

    /// For snapshots: one step, no prompts.
    init(snapshot step: Step) {
        super.init()
        steps = [.welcome, .accessibility, .bluetooth, .done].contains(step) ? [.welcome, .accessibility, .bluetooth, step == .done ? .done : .conflict("MediaMate"), .done] : [step]
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

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                page(model.step)
                    .id(model.index)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(height: 240)
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
            case .done:
                badge("checkmark", .green)
                texts(Strings.onbDoneTitle, Strings.onbDoneText)
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
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
