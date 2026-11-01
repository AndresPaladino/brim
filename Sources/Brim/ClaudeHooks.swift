import Foundation

/// Adds or removes Brim's hooks in ~/.claude/settings.json, leaving everything else alone.
/// Claude Code watches that file, so running sessions pick up the change.
enum ClaudeHooks {
    enum Failure: Error { case unreadable, noHook }

    /// Tests point these at temporary files instead of the real config and the app bundle.
    nonisolated(unsafe) static var settingsOverride: URL?
    nonisolated(unsafe) static var hookPathOverride: String?

    static var settingsURL: URL {
        if let settingsOverride { return settingsOverride }
        // Point at a copy for testing: BRIM_CLAUDE_SETTINGS=/path/settings.json
        if let path = ProcessInfo.processInfo.environment["BRIM_CLAUDE_SETTINGS"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    /// Claude Code keeps its settings in ~/.claude.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path) }

    static var hookCommand: String? {
        guard let path = hookPathOverride ?? Bundle.main.path(forResource: "claude-hook", ofType: "sh") else { return nil }
        return path.contains(" ") ? "'\(path)'" : path
    }

    static var isConnected: Bool {
        guard let command = hookCommand, let hooks = (try? read())?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { commands(in: $0).contains(command) }
    }

    static func connect() throws {
        guard let command = hookCommand else { throw Failure.noHook }
        var json = try read()
        var hooks = removingBrim(from: json["hooks"] as? [String: Any] ?? [:])
        func entry(_ matcher: String? = nil, timeout: Int? = nil) -> [String: Any] {
            var hook: [String: Any] = ["type": "command", "command": command]
            if let timeout { hook["timeout"] = timeout } else { hook["async"] = true }
            var e: [String: Any] = ["hooks": [hook]]
            if let matcher { e["matcher"] = matcher }
            return e
        }
        // Permission requests wait for the notch; everything else is async.
        let wanted: [String: [String: Any]] = [
            "PermissionRequest": entry(timeout: 3600),
            "PreToolUse": entry("AskUserQuestion", timeout: 10),
            "Notification": entry("idle_prompt"),
            "Stop": entry(), "StopFailure": entry(), "UserPromptSubmit": entry(), "SessionEnd": entry(),
        ]
        for (event, e) in wanted { hooks[event] = (hooks[event] as? [Any] ?? []) + [e] }
        json["hooks"] = hooks
        try write(json)
    }

    static func disconnect() throws {
        var json = try read()
        let hooks = removingBrim(from: json["hooks"] as? [String: Any] ?? [:])
        json["hooks"] = hooks.isEmpty ? nil : hooks
        try write(json)
    }

    // MARK: - File

    /// A missing file is an empty config. An unreadable file is never overwritten.
    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return json
    }

    private static func write(_ json: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HookFile.backup(settingsURL) { text in
            let hooks = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["hooks"] as? [String: Any] ?? [:]
            return hooks.values.contains { commands(in: $0).contains { HookFile.isBrim($0, script: "claude-hook.sh") } }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Hooks

    private static func commands(in entries: Any) -> [String] {
        (entries as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// Removes every Brim entry, including ones from other copies of the app.
    static func removingBrim(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { out[event] = value; continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let others = list.filter { !HookFile.isBrim($0["command"] as? String ?? "", script: "claude-hook.sh") }
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

/// What Claude's and Codex's hook files have in common.
enum HookFile {
    /// Brim's script from this or any other copy of the app (…/Contents/Resources/<script>, quoted
    /// when the path has spaces). A user's own script with a similar name is not Brim's.
    static func isBrim(_ command: String, script: String) -> Bool {
        var path = command.trimmingCharacters(in: .whitespaces)
        if path.count >= 2, let q = path.first, q == "'" || q == "\"", path.last == q { path = String(path.dropFirst().dropLast()) }
        return path.hasSuffix(".app/Contents/Resources/\(script)")
    }

    /// Copies the file to <name>.brim-backup before Brim changes it, but only while it has nothing
    /// of Brim's: the backup stays the user's last version without Brim.
    static func backup(_ url: URL, hasBrim: (String) -> Bool) throws {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: url, encoding: .utf8), !hasBrim(text) else { return }
        let copy = url.appendingPathExtension("brim-backup")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: url, to: copy)
    }
}
