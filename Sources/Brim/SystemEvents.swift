import AppKit
import IOKit.ps

/// Displays currently showing a full screen app. Recomputed on Space or app changes only.
@MainActor
final class FullscreenMonitor {
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    private(set) var displays = Set<CGDirectDisplayID>()

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    // SkyLight is private, but it is the only reliable way to get each display's Space type.
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let connection: ConnFn? = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: ConnFn.self) }
    private static let copySpaces: SpacesFn? = skyLight.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }.map { unsafeBitCast($0, to: SpacesFn.self) }
    private static let fullscreenSpaceType = 4

    private var pending: DispatchWorkItem?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
        }
        refresh()
    }

    /// Entering or leaving full screen fires several notifications and the Space can read wrong during
    /// the animation, so wait for a stable state.
    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.confirmAndApply() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Applies a change only if two reads 0.25 s apart agree.
    private func confirmAndApply() {
        let first = Self.fullscreenDisplays()
        guard first != displays else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard Self.fullscreenDisplays() == first else { self.scheduleCheck(); return }
            self.displays = first
            self.onChange?(first)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func refresh() {
        let now = Self.fullscreenDisplays()
        guard now != displays else { return }
        displays = now
        onChange?(now)
    }

    private static func fullscreenDisplays() -> Set<CGDirectDisplayID> {
        guard let connection, let copySpaces,
              let info = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return fullscreenDisplays(in: info, byUUID: displaysByUUID())
    }

    private static func displaysByUUID() -> [String: CGDirectDisplayID] {
        Dictionary(NSScreen.screens.compactMap { s -> (String, CGDirectDisplayID)? in
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, uuid) as String, id)
        }, uniquingKeysWith: { first, _ in first }) // mirrored displays can share a UUID
    }

    /// Displays whose current Space is a full screen app, from SkyLight's managed display spaces.
    static func fullscreenDisplays(in info: [[String: Any]], byUUID: [String: CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        var result = Set<CGDirectDisplayID>()
        for display in info {
            guard let current = display["Current Space"] as? [String: Any],
                  current["type"] as? Int == fullscreenSpaceType,
                  let identifier = display["Display Identifier"] as? String else { continue }
            // With "Displays have separate Spaces" off, every display shares the "Main" Space.
            if identifier == "Main" { return Set(byUUID.values) }
            if let id = byUUID[identifier] { result.insert(id) }
        }
        return result
    }
}

/// Charger plugged, unplugged, and charge limit reached. Driven by IOPS notifications.
@MainActor
final class PowerMonitor {
    enum Event { case plugged(percent: Int, alreadyFull: Bool), unplugged(percent: Int), full(percent: Int), low(percent: Int) }
    /// Low battery alerts fire once when crossing each threshold downwards.
    private static let lowThresholds = [20, 10]
    var onEvent: ((Event) -> Void)?

    private var source: CFRunLoopSource?
    private var last: (onAC: Bool, charging: Bool, percent: Int)?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.changed() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        last = Self.read().map { ($0.onAC, $0.charging, $0.percent) }
    }

    private static func read() -> (onAC: Bool, charging: Bool, charged: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let percent = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let charged = d[kIOPSIsChargedKey] as? Bool ?? false
            return (onAC, charging, charged, percent)
        }
        return nil
    }

    private func changed() {
        guard let now = Self.read() else { return }
        defer { last = (now.onAC, now.charging, now.percent) }
        guard let last else { return }
        if let event = Self.event(from: last, to: now) { onEvent?(event) }
    }

    /// The alert for a change in the power source, if any.
    static func event(from last: (onAC: Bool, charging: Bool, percent: Int), to now: (onAC: Bool, charging: Bool, charged: Bool, percent: Int)) -> Event? {
        if now.onAC && !last.onAC {
            // Charging starts a moment after plugging in, so check "charged" instead of "charging".
            return .plugged(percent: now.percent, alreadyFull: now.charged || now.percent >= 100)
        } else if !now.onAC && last.onAC {
            return .unplugged(percent: now.percent)
        } else if now.onAC && last.charging && !now.charging {
            // Still plugged in but no longer charging: the charge limit was reached.
            return .full(percent: now.percent)
        } else if !now.onAC, lowThresholds.contains(where: { last.percent > $0 && now.percent <= $0 }) {
            return .low(percent: now.percent)
        }
        return nil
    }
}
