import AppKit
import CoreAudio
import AudioToolbox

/// Volume and mute of the current output. Read on each key press, no listeners.
enum SystemVolume {
    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func settable(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &addr, &ok) == noErr && ok.boolValue
    }

    /// False for outputs without volume control (HDMI). The key then goes to macOS as usual.
    static var isControllable: Bool {
        guard let dev = defaultOutput() else { return false }
        return settable(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    }

    static var volume: Float {
        get {
            guard let dev = defaultOutput() else { return 0 }
            var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        set {
            guard let dev = defaultOutput() else { return }
            var v = Float32(min(1, max(0, newValue)))
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static var isMuted: Bool {
        get {
            guard let dev = defaultOutput() else { return false }
            var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioDevicePropertyMute)
            return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
        }
        set {
            guard let dev = defaultOutput(), settable(dev, kAudioDevicePropertyMute) else { return }
            var m = UInt32(newValue ? 1 : 0)
            var addr = address(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

/// Built-in display brightness through DisplayServices (private framework).
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    private static var builtinDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isControllable: Bool { getFn != nil && setFn != nil && builtinDisplay != nil }

    static var brightness: Float {
        get {
            guard let d = builtinDisplay, let getFn else { return 0 }
            var b = Float(0)
            return getFn(d, &b) == 0 ? b : 0
        }
        set {
            guard let d = builtinDisplay, let setFn else { return }
            _ = setFn(d, min(1, max(0, newValue)))
        }
    }
}
