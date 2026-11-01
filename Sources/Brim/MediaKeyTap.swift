import AppKit
import os

enum MediaKey {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

private let log = Logger(subsystem: "com.andrespaladino.brim", category: "keys")

/// Catches the volume and brightness keys (NX_SYSDEFINED events) before macOS shows its own HUD.
/// Needs Accessibility.
final class MediaKeyTap {
    /// Returns true when Brim handled the key and macOS should not see it.
    typealias Handler = (_ key: MediaKey, _ fineStep: Bool) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose keyDown was consumed; their keyUp is consumed too.
    var consumed = Set<Int>()

    init(handler: @escaping Handler) { self.handler = handler }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create the event tap (is Accessibility granted?)")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
        log.info("Event tap active")
        return true
    }

    /// Key code and down/up from an NX_SYSDEFINED event's data1, or nil for other states.
    static func decode(data1: Int) -> (code: Int, down: Bool)? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return (code, state == 0xA)
    }

    /// macOS may disable the tap during sleep.
    func ensureEnabled() { reenable() }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func handle(code: Int, down: Bool, fine: Bool) -> Bool {
        let key: MediaKey
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        default:
            log.debug("Unhandled special key: \(code)")
            return false
        }
        guard down else { return consumed.remove(code) != nil }
        let handled = handler(key, fine)
        if handled { consumed.insert(code) }
        return handled
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    guard let (code, down) = MediaKeyTap.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
    // Option + Shift: quarter steps, as in macOS.
    let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
    let swallow = me.handle(code: code, down: down, fine: fine)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
