import AppKit
import CoreAudio
import IOBluetooth
import os

private let log = Logger(subsystem: "com.andrespaladino.brim", category: "devices")

struct AudioDeviceEvent: Identifiable, Equatable {
    enum Status { case connected, lowBattery }
    enum Visual: Equatable {
        /// macOS's own render, one image per earbud.
        case buds(left: NSImage, right: NSImage)
        case symbol(String)
    }

    let id = UUID()
    let name: String
    let status: Status
    let battery: Int?
    let visual: Visual
}

/// New audio outputs from CoreAudio (Bluetooth, USB, jack, AirPlay), with Bluetooth details when available.
@MainActor
final class AudioDeviceMonitor {
    var onConnect: ((AudioDeviceEvent) -> Void)?

    private var known = Set<AudioDeviceID>()
    private var dataSources: [AudioDeviceID: UInt32] = [:]
    private var dataSourceListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var lowBatteryAlerted = Set<String>()
    private static let headphonesSource: UInt32 = 0x6864_706E // 'hdpn'
    /// Bluetooth battery levels show up a moment after connecting.
    private static let settleDelay: TimeInterval = 1.0

    func start() {
        known = Set(Self.outputDevices())
        known.forEach(watchDataSource)
        var addr = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
    }

    /// Called when something else already woke the app (a track change), never on a timer.
    func lowBatteryEvent() -> AudioDeviceEvent? {
        let id = AudioOutputs.defaultOutput
        guard Self.uint(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth,
              let event = describe(id, status: .lowBattery), let battery = event.battery else { return nil }
        let uid = Self.string(id, kAudioDevicePropertyDeviceUID) ?? event.name
        if battery > 20 { lowBatteryAlerted.remove(uid); return nil }
        guard battery <= 10, !lowBatteryAlerted.contains(uid) else { return nil }
        lowBatteryAlerted.insert(uid)
        return event
    }

    // MARK: - Events

    private func devicesChanged() {
        let now = Set(Self.outputDevices())
        let added = now.subtracting(known)
        known.subtracting(now).forEach(unwatchDataSource)
        known = now
        for id in added {
            watchDataSource(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
                guard let self, self.known.contains(id), let event = self.describe(id, status: .connected) else { return }
                self.onConnect?(event)
            }
        }
    }

    /// Wired headphones can show up as a data source change on the built-in output.
    private func watchDataSource(_ id: AudioDeviceID) {
        var addr = Self.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        guard dataSourceListeners[id] == nil, AudioObjectHasProperty(id, &addr) else { return }
        dataSources[id] = Self.uint(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.dataSourceChanged(id) }
        }
        if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr { dataSourceListeners[id] = block }
    }

    /// CoreAudio can reuse a device ID, so drop the listener when the device goes away.
    private func unwatchDataSource(_ id: AudioDeviceID) {
        dataSources[id] = nil
        guard let block = dataSourceListeners.removeValue(forKey: id) else { return }
        var addr = Self.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
    }

    private func dataSourceChanged(_ id: AudioDeviceID) {
        let new = Self.uint(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        let old = dataSources[id]
        dataSources[id] = new
        guard new == Self.headphonesSource, old != Self.headphonesSource else { return }
        let name = Self.dataSourceName(id, new) ?? Strings.headphones
        onConnect?(AudioDeviceEvent(name: name, status: .connected, battery: nil, visual: .symbol("headphones")))
    }

    // MARK: - Description

    private func describe(_ id: AudioDeviceID, status: AudioDeviceEvent.Status) -> AudioDeviceEvent? {
        guard let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
        let transport = Self.uint(id, kAudioDevicePropertyTransportType)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return bluetoothEvent(id, name: name, status: status)
        case kAudioDeviceTransportTypeBuiltIn:
            return AudioDeviceEvent(name: name, status: status, battery: nil, visual: .symbol("headphones"))
        case kAudioDeviceTransportTypeAirPlay:
            return AudioDeviceEvent(name: name, status: status, battery: nil, visual: .symbol(DeviceSymbols.pick("airplay.audio", "airplayaudio")))
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI:
            let symbol = DeviceSymbols.looksLikeHeadphones(name) ? "headphones" : DeviceSymbols.pick("hifireceiver.fill", "speaker.wave.2.fill")
            return AudioDeviceEvent(name: name, status: status, battery: nil, visual: .symbol(symbol))
        default:
            return AudioDeviceEvent(name: name, status: status, battery: nil, visual: .symbol("speaker.wave.2.fill"))
        }
    }

    private func bluetoothEvent(_ id: AudioDeviceID, name: String, status: AudioDeviceEvent.Status) -> AudioDeviceEvent {
        guard let bt = Self.bluetoothDevice(uid: Self.string(id, kAudioDevicePropertyDeviceUID), name: name) else {
            return AudioDeviceEvent(name: name, status: status, battery: nil, visual: .symbol(DeviceSymbols.forName(name) ?? "headphones"))
        }
        let product = Self.int(bt, "productID")
        let vendor = Self.int(bt, "vendorID")
        let left = Self.int(bt, "batteryPercentLeft"), right = Self.int(bt, "batteryPercentRight")
        let single = Self.int(bt, "batteryPercentSingle"), combined = Self.int(bt, "batteryPercentCombined")
        let buds = [left, right].filter { $0 > 0 }
        let battery = buds.min() ?? (single > 0 ? single : combined > 0 ? combined : nil)

        let visual: AudioDeviceEvent.Visual
        if vendor == 0x004C, let art = DeviceArtwork.buds(productID: product) {
            visual = .buds(left: art.left, right: art.right)
        } else {
            visual = .symbol(DeviceSymbols.forApple(productID: vendor == 0x004C ? product : nil)
                ?? DeviceSymbols.forName(name)
                ?? DeviceSymbols.forBluetoothClass(Int(bt.deviceClassMinor)))
        }
        return AudioDeviceEvent(name: name, status: status, battery: battery, visual: visual)
    }

    /// CoreAudio puts the Bluetooth address inside the device UID.
    private static func bluetoothDevice(uid: String?, name: String) -> IOBluetoothDevice? {
        if let uid, let r = uid.range(of: "([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}", options: .regularExpression),
           let d = IOBluetoothDevice(addressString: uid[r].replacingOccurrences(of: ":", with: "-")) {
            return d
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { $0.isConnected() && $0.name == name }
    }

    /// Private IOBluetoothDevice properties (battery, model), when present.
    private static func int(_ d: IOBluetoothDevice, _ key: String) -> Int {
        guard d.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (d.value(forKey: key) as? NSNumber)?.intValue ?? 0
    }

    // MARK: - CoreAudio

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var addr = address(sel, scope)
        var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v?.takeRetainedValue() as String?
    }

    private static func dataSourceName(_ id: AudioDeviceID, _ source: UInt32) -> String? {
        var src = source
        var name: Unmanaged<CFString>?
        return withUnsafeMutablePointer(to: &src) { srcPtr in
            withUnsafeMutablePointer(to: &name) { namePtr in
                var t = AudioValueTranslation(mInputData: srcPtr, mInputDataSize: 4, mOutputData: namePtr,
                                              mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var addr = address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioDevicePropertyScopeOutput)
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return nil }
                return namePtr.pointee?.takeRetainedValue() as String?
            }
        }
    }

    /// Visible devices with output channels, excluding displays and virtual devices.
    private static func outputDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let excluded: Set<UInt32> = [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                                     kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                     kAudioDeviceTransportTypeAutoAggregate]
        return ids.filter { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var s = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return false }
            if uint(id, kAudioDevicePropertyIsHidden) != 0 { return false }
            return !excluded.contains(uint(id, kAudioDevicePropertyTransportType))
        }
    }
}

/// AirPods renders that ship with macOS, loaded once on first use.
enum DeviceArtwork {
    private static let bluetoothUI = "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/Resources"
    private static let headphoneAssets = Bundle(path: "/System/Library/PrivateFrameworks/HeadphoneAssets.framework")

    /// Product ID to code name (0x2027 → "B788"), from macOS's own tables.
    @MainActor private static let codenames: [Int: String] = {
        var map: [Int: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bluetoothUI)) ?? []
        for f in files where f.hasPrefix("AssetPaths-") && f.hasSuffix(".plist") {
            guard let dict = NSDictionary(contentsOfFile: "\(bluetoothUI)/\(f)") as? [String: Any] else { continue }
            for (key, value) in dict {
                guard let pid = Int(key.replacingOccurrences(of: "0x", with: ""), radix: 16),
                      let entry = value as? [String: Any], let image = entry["ImageName"] as? String else { continue }
                map[pid] = String(image.prefix { $0.isLetter || $0.isNumber })
            }
        }
        return map
    }()

    @MainActor
    static func buds(productID: Int) -> (left: NSImage, right: NSImage)? {
        guard let code = codenames[productID],
              let left = headphoneAssets?.image(forResource: "\(code)_airpod_left"),
              let right = headphoneAssets?.image(forResource: "\(code)_airpod_right") else { return nil }
        return (left, right)
    }
}

/// SF Symbols when there is no render: by Apple model, by name, or by device class.
enum DeviceSymbols {
    private static let apple: [Int: [String]] = [
        0x2002: ["airpods"], 0x200F: ["airpods"],
        0x2013: ["airpods.gen3", "airpods"],
        0x2019: ["airpods.gen4", "airpods.gen3", "airpods"], 0x201B: ["airpods.gen4", "airpods.gen3", "airpods"],
        0x200E: ["airpods.pro"], 0x2014: ["airpods.pro"], 0x2024: ["airpods.pro"], 0x2027: ["airpods.pro"],
        0x200A: ["airpods.max", "airpodsmax"], 0x201F: ["airpods.max", "airpodsmax"],
        0x200B: ["beats.powerbeats.pro", "beats.earphones"], 0x2011: ["beats.studiobuds", "beats.earphones"],
        0x2012: ["beats.fitpro", "beats.earphones"], 0x2006: ["beats.headphones"], 0x2009: ["beats.headphones"],
    ]

    /// The first symbol that exists on this macOS version.
    static func pick(_ names: String...) -> String { pick(names) }

    static func pick(_ names: [String]) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }

    static func forApple(productID: Int?) -> String? {
        guard let productID, let names = apple[productID] else { return nil }
        return pick(names)
    }

    static func forName(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("airpods max") { return pick("airpods.max", "airpodsmax") }
        if n.contains("airpods pro") { return pick("airpods.pro") }
        if n.contains("airpods") { return pick("airpods") }
        if n.contains("powerbeats") || n.contains("beats fit") || n.contains("buds") { return pick("beats.earphones", "earbuds") }
        if n.contains("beats") { return pick("beats.headphones") }
        return nil
    }

    static func looksLikeHeadphones(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["headphone", "headset", "auricular", "earbud", "buds"].contains { n.contains($0) }
    }

    /// Bluetooth minor device class.
    static func forBluetoothClass(_ minor: Int) -> String {
        switch minor {
        case 0x01, 0x02, 0x06: return "headphones"
        case 0x05, 0x07, 0x0A: return pick("hifispeaker.fill", "speaker.wave.2.fill")
        case 0x08: return "car.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}
