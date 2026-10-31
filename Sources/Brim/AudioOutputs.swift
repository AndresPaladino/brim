import AppKit
import CoreAudio

enum AudioOutputs {
    struct Device { let id: AudioDeviceID; let name: String }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var devices: [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var ssize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &ssize) == noErr, ssize > 0 else { return nil }
            var nameAddr = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &name) == noErr,
                  let n = name?.takeRetainedValue() else { return nil }
            return Device(id: id, name: n as String)
        }
    }

    static var defaultOutput: AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    @MainActor
    static func showMenu() {
        let menu = NSMenu()
        let current = defaultOutput
        for d in devices {
            let item = NSMenuItem(title: d.name, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.tag = Int(d.id)
            item.state = d.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func pick(_ item: NSMenuItem) { AudioOutputs.setDefaultOutput(AudioDeviceID(item.tag)) }
    }
}
