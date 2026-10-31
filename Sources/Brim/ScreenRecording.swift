import AppKit

struct ScreenRecording: Equatable {
    let start: Date
    /// macOS recording (⌘⇧5 or QuickTime), which ⌘⌃Esc stops. Other apps (Zoom, OBS) only get the indicator.
    let stoppable: Bool
}

/// Reports when something starts or stops capturing the screen, through WindowServer notifications
/// 1502 and 1503. No polling.
@MainActor
final class ScreenRecordingMonitor {
    var onChange: ((ScreenRecording?) -> Void)?
    private(set) var current: ScreenRecording?

    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterFn = @convention(c) (NotifyProc?, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias WatcherFn = @convention(c) () -> Bool
    // Private WindowServer functions, looked up at runtime so a future macOS without them just disables the feature.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    private static let register: RegisterFn? = dlsym(defaultHandle, "CGSRegisterNotifyProc").map { unsafeBitCast($0, to: RegisterFn.self) }
    private static let watcherPresent: WatcherFn? = dlsym(defaultHandle, "CGSIsScreenWatcherPresent").map { unsafeBitCast($0, to: WatcherFn.self) }
    private static let started: UInt32 = 1502
    private static let stopped: UInt32 = 1503

    private static weak var instance: ScreenRecordingMonitor?
    private static let callback: NotifyProc = { _, _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { ScreenRecordingMonitor.instance?.changed() } }
    }

    private var pending: DispatchWorkItem?

    func start() {
        guard Self.instance == nil, let register = Self.register, Self.watcherPresent != nil else { return }
        Self.instance = self
        _ = register(Self.callback, Self.started, nil)
        _ = register(Self.callback, Self.stopped, nil)
        // A recording may already be running.
        changed()
    }

    /// Same as pressing ⌘⌃Esc: macOS stops the recording and saves it.
    func stop() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) // Esc
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    private func changed() {
        pending?.cancel()
        guard Self.watcherPresent?() == true else { set(nil); return }
        guard current == nil else { return }
        // Screenshots trigger it too. Only show it if capture is still going half a second later.
        let start = Date()
        let work = DispatchWorkItem { [weak self] in
            guard Self.watcherPresent?() == true else { return }
            self?.set(ScreenRecording(start: start, stoppable: Self.systemRecorderRunning()))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func set(_ recording: ScreenRecording?) {
        guard current != recording else { return }
        current = recording
        onChange?(recording)
    }

    private static func systemRecorderRunning() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.QuickTimePlayerX" }) { return true }
        return processNames().contains("screencapture")
    }

    static func processNames() -> Set<String> {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(String(cString: buffer)) }
        }
        return names
    }
}
