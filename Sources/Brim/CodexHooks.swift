import CryptoKit
import Foundation

/// Adds or removes Brim's hooks in ~/.codex/hooks.json, leaving everything else alone.
///
/// Codex skips hooks nobody has reviewed. It remembers a reviewed hook in config.toml as
/// `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]` with the SHA-256 of the hook's
/// definition, so Brim writes that entry too and the hooks work without a trip to /hooks.
enum CodexHooks {
    enum Failure: Error { case unreadable, noHook }

    static var home: URL {
        // Point at a copy for testing: BRIM_CODEX_HOME=/path/.codex
        if let path = ProcessInfo.processInfo.environment["BRIM_CODEX_HOME"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var hooksURL: URL { home.appendingPathComponent("hooks.json") }
    static var configURL: URL { home.appendingPathComponent("config.toml") }

    private static var hookCommand: String? {
        guard let path = Bundle.main.path(forResource: "codex-hook", ofType: "sh") else { return nil }
        return path.contains(" ") ? "'\(path)'" : path
    }

    /// Hooks.json event name, Codex's snake-case label for the trust key, timeout and status line.
    /// Permission requests wait for the notch; the rest return at once.
    /// Questions also wait: Brim answers them by blocking the call with the answer. Plan mode asks with
    /// request_user_input; the default mode in the Codex app with request_user_input_async.
    private static let wanted: [(event: String, label: String, matcher: String?, timeout: Int, status: String?)] = [
        ("PermissionRequest", "permission_request", nil, 3600, "Waiting for you in the notch"),
        ("PreToolUse", "pre_tool_use", Self.questionMatcher, 3600, "Waiting for you in the notch"),
        ("UserPromptSubmit", "user_prompt_submit", nil, 5, nil),
        ("Stop", "stop", nil, 5, nil),
    ]

    static let questionMatcher = "^request_user_input(_async)?$"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: home.path) }

    /// Reinstalls when an older Brim connected fewer hooks than this one uses.
    static func upgradeIfNeeded() {
        guard let command = hookCommand, let hooks = (try? readHooks())?["hooks"] as? [String: Any],
              hooks.values.contains(where: { commands(in: $0).contains(command) }) else { return }
        // Missing events, or an older matcher (the trust hash covers it).
        let current = { (w: (event: String, label: String, matcher: String?, timeout: Int, status: String?)) -> Bool in
            (hooks[w.event] as? [[String: Any]] ?? []).contains { group in
                group["matcher"] as? String == w.matcher && commands(in: [group]).contains(command)
            }
        }
        if !wanted.allSatisfy(current) { try? connect() }
    }

    static var isConnected: Bool {
        guard let command = hookCommand, let hooks = (try? readHooks())?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { commands(in: $0).contains(command) }
    }

    static func connect() throws {
        guard let command = hookCommand else { throw Failure.noHook }
        var json = try readHooks()
        var hooks = removingBrim(from: json["hooks"] as? [String: Any] ?? [:])
        var trust: [(key: String, hash: String)] = []
        for w in wanted {
            var handler: [String: Any] = ["type": "command", "command": command, "timeout": w.timeout]
            if let status = w.status { handler["statusMessage"] = status }
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher = w.matcher { group["matcher"] = matcher }
            let groups = hooks[w.event] as? [Any] ?? []
            hooks[w.event] = groups + [group]
            trust.append(("\(hooksURL.path):\(w.label):\(groups.count):0",
                          hash(event: w.label, matcher: w.matcher, command: command, timeout: w.timeout, status: w.status)))
        }
        json["hooks"] = hooks
        try writeHooks(json)
        try writeTrust(trust)
    }

    static func disconnect() throws {
        var json = try readHooks()
        let hooks = removingBrim(from: json["hooks"] as? [String: Any] ?? [:])
        json["hooks"] = hooks.isEmpty ? nil : hooks
        try writeHooks(json)
        try writeTrust([])
    }

    // MARK: - Trust

    /// Same as Codex's `version_for_toml`: SHA-256 of the normalized definition as compact JSON with
    /// sorted keys. Checked against a hook Codex itself had trusted.
    static func hash(event: String, matcher: String?, command: String, timeout: Int, status: String?) -> String {
        var handler = #"{"async":false,"command":\#(quoted(command))"#
        if let status { handler += #","statusMessage":\#(quoted(status))"# }
        handler += #","timeout":\#(timeout),"type":"command"}"#
        var identity = #"{"event_name":\#(quoted(event)),"hooks":[\#(handler)]"#
        if let matcher { identity += #","matcher":\#(quoted(matcher))"# }
        identity += "}"
        return "sha256:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A JSON string the way serde_json writes it.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// Replaces the trust entries Brim wrote before with these. Other entries stay as they are.
    private static func writeTrust(_ entries: [(key: String, hash: String)]) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.stringArray(forKey: "codexTrustKeys") ?? []
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        let stale = Set((previous + entries.map(\.key)).map { "[hooks.state.\"\($0)\"]" })
        var i = 0
        while i < lines.count {
            guard stale.contains(lines[i].trimmingCharacters(in: .whitespaces)) else { i += 1; continue }
            var end = i + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            lines.removeSubrange(i..<end)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        for e in entries { lines += ["", "[hooks.state.\"\(e.key)\"]", "trusted_hash = \"\(e.hash)\""] }
        let out = lines.joined(separator: "\n") + "\n"
        if out != text {
            try backup(configURL)
            try out.write(to: configURL, atomically: true, encoding: .utf8)
        }
        defaults.set(entries.map(\.key), forKey: "codexTrustKeys")
    }

    // MARK: - hooks.json

    /// A missing file is an empty config. An unreadable file is never overwritten.
    private static func readHooks() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return json
    }

    private static func writeHooks(_ json: [String: Any]) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try backup(hooksURL)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: hooksURL, options: .atomic)
    }

    private static func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let copy = url.appendingPathExtension("brim-backup")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: url, to: copy)
    }

    private static func commands(in entries: Any) -> [String] {
        (entries as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// Removes every Brim entry, including ones from older copies.
    private static func removingBrim(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { out[event] = value; continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let others = list.filter { !(($0["command"] as? String ?? "").contains("codex-hook.sh")) }
                if others.isEmpty { return nil }
                var e = entry
                e["hooks"] = others
                return e
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }
}
