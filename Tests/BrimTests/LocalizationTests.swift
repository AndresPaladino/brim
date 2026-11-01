import Testing
import Foundation
@testable import Brim

/// English and Spanish strings stay in step with each other and with the code.
@Suite struct LocalizationTests {
    static func table(_ lang: String) -> [String: String] {
        let url = Repo.resources.appendingPathComponent("\(lang).lproj/Localizable.strings")
        let data = (try? Data(contentsOf: url)) ?? Data()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] ?? [:]
    }
    static let en = table("en"), es = table("es")

    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+#0]*\d*(\.\d+)?(hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF%]"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.filter { $0 != "%%" }
    }

    @Test func bothTablesParse() {
        #expect(Self.en.count > 50)
        #expect(Self.es.count > 50)
    }

    @Test func sameKeys() {
        let onlyEn = Set(Self.en.keys).subtracting(Self.es.keys), onlyEs = Set(Self.es.keys).subtracting(Self.en.keys)
        #expect(onlyEn.isEmpty, "missing in es: \(onlyEn.sorted())")
        #expect(onlyEs.isEmpty, "missing in en: \(onlyEs.sorted())")
    }

    @Test func sameFormatSpecifiers() {
        for (key, en) in Self.en {
            guard let es = Self.es[key] else { continue }
            #expect(Self.specifiers(en).sorted() == Self.specifiers(es).sorted(), "\(key): \"\(en)\" vs \"\(es)\"")
        }
    }

    @Test func noEmptyOrUntranslated() {
        for (key, es) in Self.es {
            #expect(!es.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is empty in es")
        }
        // Spanish identical to English is fine for names ("Bluetooth"), suspicious for sentences.
        let same = Self.en.filter { Self.es[$0.key] == $0.value && $0.value.split(separator: " ").count > 2 }
        #expect(same.isEmpty, "untranslated: \(same.keys.sorted())")
    }

    @Test func everyKeyInCodeExists() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Repo.sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"\bt\("([a-zA-Z0-9_.]+)"\)"#)
        var used = Set<String>()
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) { used.insert((text as NSString).substring(with: m.range(at: 1))) }
        }
        #expect(used.count > 50)
        let missing = used.subtracting(Self.en.keys)
        #expect(missing.isEmpty, "used but not defined: \(missing.sorted())")
        let unused = Set(Self.en.keys).subtracting(used)
        #expect(unused.isEmpty, "defined but unused: \(unused.sorted())")
    }

    /// %d with a Swift Int works on 64-bit by luck; %ld is the right specifier.
    @Test func integerSpecifiers() {
        let plainD = Self.en.filter { Self.specifiers($0.value).contains { $0.hasSuffix("d") && !$0.contains("l") } }
        #expect(plainD.isEmpty, "\(plainD.keys.sorted())")
    }

    @Test func infoPlistStrings() {
        for lang in ["en", "es"] {
            let url = Repo.resources.appendingPathComponent("\(lang).lproj/InfoPlist.strings")
            let data = (try? Data(contentsOf: url)) ?? Data()
            let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
            #expect(table?.isEmpty == false, "\(lang) InfoPlist.strings")
        }
    }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func defaultsAreOn() {
        let p = makePreferences()
        #expect(p.displays == .all && p.openOnHover && p.volumeHUD && p.mediaAtRest && p.deviceAlerts && p.lowBattery)
        #expect(p.chargeAlerts && p.macLowBattery && p.screenRecording && p.claudeAlerts && p.claudeApprove && p.codexAlerts)
    }

    @Test func changesPersistAndNotify() {
        let name = "brim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let p = Preferences(defaults: defaults)
        var calls: [String] = []
        p.onDisplaysChange = { calls.append("displays") }
        p.onMediaAtRestChange = { calls.append("media") }
        p.onClaudeChange = { calls.append("claude") }
        p.onScreenRecordingChange = { calls.append("rec") }
        p.displays = .external
        p.mediaAtRest = false
        p.claudeAlerts = false
        p.codexAlerts = false
        p.screenRecording = false
        p.volumeHUD = false
        #expect(calls == ["displays", "media", "claude", "claude", "rec"])
        let again = Preferences(defaults: defaults)
        #expect(again.displays == .external && !again.mediaAtRest && !again.claudeAlerts && !again.volumeHUD)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func unknownDisplayValueFallsBack() {
        let name = "brim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("mirror", forKey: "displays")
        #expect(Preferences(defaults: defaults).displays == .all)
        defaults.removePersistentDomain(forName: name)
    }
}
