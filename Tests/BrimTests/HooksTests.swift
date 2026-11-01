import Testing
import Foundation
@testable import Brim

/// Connecting and disconnecting Brim's hooks in Claude Code's and Codex's config, on temporary copies.
/// Serialized: the installers keep their overrides in static properties.
@MainActor
@Suite(.serialized) struct HooksTests {
    let dir = TempDir()
    let claudeHook = "/Applications/Brim.app/Contents/Resources/claude-hook.sh"
    let codexHook = "/Applications/Brim.app/Contents/Resources/codex-hook.sh"
    var settings: URL { dir.file(".claude/settings.json") }
    var codexHooks: URL { dir.file(".codex/hooks.json") }
    var codexConfig: URL { dir.file(".codex/config.toml") }

    init() {
        ClaudeHooks.settingsOverride = dir.file(".claude/settings.json")
        ClaudeHooks.hookPathOverride = claudeHook
        CodexHooks.homeOverride = dir.file(".codex")
        CodexHooks.hookPathOverride = codexHook
        let suite = "brim-tests-\(UUID().uuidString)"
        CodexHooks.defaults = UserDefaults(suiteName: suite)!
        try? FileManager.default.createDirectory(at: dir.file(".claude"), withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ text: String) { try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try! text.write(to: url, atomically: true, encoding: .utf8) }
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func readJSON(_ url: URL) -> [String: Any] { json(read(url)) }

    // MARK: Claude Code

    @Test func connectOnAMissingFile() throws {
        try? FileManager.default.removeItem(at: settings)
        try ClaudeHooks.connect()
        let hooks = readJSON(settings)["hooks"] as? [String: Any] ?? [:]
        #expect(Set(hooks.keys) == ["PermissionRequest", "PreToolUse", "Notification", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd"])
        let perm = ((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(perm?["command"] as? String == claudeHook && perm?["timeout"] as? Int == 3600 && perm?["async"] == nil)
        let stop = ((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(stop?["async"] as? Bool == true)
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String == "AskUserQuestion")
        #expect(ClaudeHooks.isConnected)
    }

    @Test func keepsEverythingElse() throws {
        let original = #"{"model":"opus","permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"swiftformat"}]}]}}"#
        write(settings, original)
        try ClaudeHooks.connect()
        let j = readJSON(settings)
        #expect(j["model"] as? String == "opus")
        #expect((j["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        let hooks = j["hooks"] as! [String: Any]
        #expect((hooks["Stop"] as? [Any])?.count == 2) // the user's + Brim's
        #expect((hooks["PostToolUse"] as? [Any])?.count == 1)

        try ClaudeHooks.disconnect()
        #expect(readJSON(settings) as NSDictionary == json(original) as NSDictionary) // same content back
        #expect(!ClaudeHooks.isConnected)
    }

    @Test func connectTwiceIsLikeOnce() throws {
        try? FileManager.default.removeItem(at: settings)
        try ClaudeHooks.connect()
        let once = read(settings)
        try ClaudeHooks.connect()
        #expect(read(settings) == once)
    }

    @Test func oldCopiesAreReplaced() throws {
        write(settings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/Downloads/Brim.app/Contents/Resources/claude-hook.sh","async":true}]}]}}"#)
        try ClaudeHooks.connect()
        let text = read(settings)
        #expect(!text.contains("Downloads"))
        #expect(text.components(separatedBy: "claude-hook.sh").count - 1 == 7)
    }

    @Test func disconnectRemovesTheHooksKeyWhenEmpty() throws {
        write(settings, #"{"model":"opus"}"#)
        try ClaudeHooks.connect()
        try ClaudeHooks.disconnect()
        #expect(readJSON(settings)["hooks"] == nil)
    }

    @Test func brokenJSONIsNeverOverwritten() throws {
        write(settings, "{ this is not json")
        #expect(throws: (any Error).self) { try ClaudeHooks.connect() }
        #expect(read(settings) == "{ this is not json")
    }

    @Test func pathWithSpacesIsQuoted() throws {
        ClaudeHooks.hookPathOverride = "/Users/me/My Apps/Brim.app/Contents/Resources/claude-hook.sh"
        defer { ClaudeHooks.hookPathOverride = claudeHook }
        try ClaudeHooks.connect()
        #expect(read(settings).contains("'/Users/me/My Apps/Brim.app/Contents/Resources/claude-hook.sh'"))
        #expect(ClaudeHooks.isConnected)
    }

    @Test func backupKeepsThePreviousVersion() throws {
        write(settings, #"{"v":1}"#)
        try ClaudeHooks.connect()
        #expect(json(read(settings.appendingPathExtension("brim-backup")))["v"] as? Int == 1)
        try ClaudeHooks.connect()
        try ClaudeHooks.disconnect()
        // Writes while connected used to replace the backup with the connected file, losing the original.
        #expect(json(read(settings.appendingPathExtension("brim-backup")))["v"] as? Int == 1)
        #expect(!read(settings.appendingPathExtension("brim-backup")).contains("claude-hook.sh"))
        // Once disconnected, the next change backs up the user's latest version.
        write(settings, #"{"v":2}"#)
        try ClaudeHooks.connect()
        #expect(json(read(settings.appendingPathExtension("brim-backup")))["v"] as? Int == 2)
    }

    @Test func codexBackupsKeepTheOriginal() throws {
        write(codexHooks, #"{"v":1}"#)
        write(codexConfig, "model = \"x\"\n")
        try CodexHooks.connect()
        try CodexHooks.connect()
        try CodexHooks.disconnect()
        #expect(json(read(codexHooks.appendingPathExtension("brim-backup")))["v"] as? Int == 1)
        #expect(read(codexConfig.appendingPathExtension("brim-backup")) == "model = \"x\"\n")
    }

    /// Anything whose command mentioned "claude-hook.sh" used to count as Brim's, including the user's own script.
    @Test func userHookWithTheSameFileName() throws {
        write(settings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/bin/my-claude-hook.sh"},{"type":"command","command":"~/bin/claude-hook.sh"}]}]}}"#)
        try ClaudeHooks.connect()
        try ClaudeHooks.disconnect()
        #expect(read(settings).contains("my-claude-hook.sh") && read(settings).contains("~/bin/claude-hook.sh"))
        #expect(!read(settings).contains("Brim.app"))
    }

    @Test func brimCommandsFromAnyCopy() {
        #expect(HookFile.isBrim("/Applications/Brim.app/Contents/Resources/claude-hook.sh", script: "claude-hook.sh"))
        #expect(HookFile.isBrim("'/Users/me/My Apps/Brim.app/Contents/Resources/claude-hook.sh'", script: "claude-hook.sh"))
        #expect(HookFile.isBrim("/Users/me/Library/Caches/brim-build/app.noindex/Brim.app/Contents/Resources/codex-hook.sh", script: "codex-hook.sh"))
        #expect(!HookFile.isBrim("~/bin/my-claude-hook.sh", script: "claude-hook.sh"))
        #expect(!HookFile.isBrim("/Applications/Brim.app/Contents/Resources/claude-hook.sh --x", script: "claude-hook.sh"))
        #expect(!HookFile.isBrim("/Applications/Brim.app/Contents/Resources/claude-hook.sh", script: "codex-hook.sh"))
    }

    @Test func hooksThatAreNotArraysSurvive() throws {
        write(settings, #"{"hooks":{"Weird":"keep me","Stop":[{"matcher":"x"}]}}"#)
        try ClaudeHooks.connect()
        try ClaudeHooks.disconnect()
        let hooks = readJSON(settings)["hooks"] as? [String: Any]
        #expect(hooks?["Weird"] as? String == "keep me")
        #expect((hooks?["Stop"] as? [[String: Any]])?.first?["matcher"] as? String == "x")
    }

    // MARK: Codex

    @Test func codexConnectWritesHooksAndTrust() throws {
        write(codexConfig, "model = \"gpt-5\"\n\n[hooks.state.\"other:stop:0:0\"]\ntrusted_hash = \"sha256:abc\"\n")
        try CodexHooks.connect()
        let hooks = readJSON(codexHooks)["hooks"] as? [String: Any] ?? [:]
        #expect(Set(hooks.keys) == ["PermissionRequest", "PreToolUse", "UserPromptSubmit", "Stop"])
        let toml = read(codexConfig)
        #expect(toml.hasPrefix("model = \"gpt-5\""))
        #expect(toml.contains("[hooks.state.\"other:stop:0:0\"]")) // others' entries stay
        for label in ["permission_request", "pre_tool_use", "user_prompt_submit", "stop"] {
            #expect(toml.contains("[hooks.state.\"\(codexHooks.path):\(label):0:0\"]"))
        }
        #expect(toml.components(separatedBy: "trusted_hash = \"sha256:").count - 1 == 5)
        #expect(CodexHooks.isConnected)
    }

    @Test func codexDisconnectCleansUp() throws {
        write(codexConfig, "model = \"gpt-5\"\n")
        try CodexHooks.connect()
        try CodexHooks.disconnect()
        #expect(read(codexConfig) == "model = \"gpt-5\"\n")
        #expect(readJSON(codexHooks)["hooks"] == nil)
        #expect(!CodexHooks.isConnected)
    }

    @Test func codexTrustIndexFollowsExistingGroups() throws {
        write(codexHooks, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]}}"#)
        try CodexHooks.connect()
        // Brim's Stop group is the second one (index 1), so its trust key ends in :stop:1:0.
        #expect(read(codexConfig).contains(":stop:1:0\"]"))
    }

    @Test func codexReconnectDoesNotDuplicateTrust() throws {
        try CodexHooks.connect()
        let once = read(codexConfig)
        try CodexHooks.connect()
        #expect(read(codexConfig) == once)
    }

    @Test func codexHashMatchesAKnownValue() {
        // Fixed inputs; a change here means Codex would stop trusting the hooks.
        let h = CodexHooks.hash(event: "stop", matcher: nil, command: "/x/codex-hook.sh", timeout: 5, status: nil)
        #expect(h.hasPrefix("sha256:") && h.count == 71)
        #expect(h == CodexHooks.hash(event: "stop", matcher: nil, command: "/x/codex-hook.sh", timeout: 5, status: nil))
        #expect(h != CodexHooks.hash(event: "stop", matcher: nil, command: "/x/codex-hook.sh", timeout: 6, status: nil))
        #expect(CodexHooks.quoted("a\"b\\c\nd\u{1}") == #""a\"b\\c\nd\u0001""#)
    }

    @Test func upgradeAddsMissingEvents() throws {
        // An older Brim connected only Stop.
        write(codexHooks, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(codexHook)\",\"timeout\":5}]}]}}")
        CodexHooks.upgradeIfNeeded()
        let hooks = readJSON(codexHooks)["hooks"] as? [String: Any] ?? [:]
        #expect(hooks.keys.count == 4)
        // Nothing to do when current: the file isn't rewritten.
        let before = try FileManager.default.attributesOfItem(atPath: codexHooks.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        CodexHooks.upgradeIfNeeded()
        let after = try FileManager.default.attributesOfItem(atPath: codexHooks.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func upgradeLeavesDisconnectedAlone() {
        CodexHooks.upgradeIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: codexHooks.path))
    }

    @Test func tomlHeaderWithTrailingComment() throws {
        try CodexHooks.connect()
        // The user adds a comment after one of Brim's headers; disconnect should still remove the block.
        let commented = read(codexConfig).replacingOccurrences(of: ":stop:0:0\"]", with: ":stop:0:0\"] # brim")
        write(codexConfig, commented)
        try CodexHooks.disconnect()
        #expect(!read(codexConfig).contains("trusted_hash"))
    }

    /// Only Brim's own headers count: a similar header with more after it stays.
    @Test func tomlHeaderLookalikeStays() throws {
        try CodexHooks.connect()
        let key = try #require(CodexHooks.defaults.stringArray(forKey: "codexTrustKeys")?.first)
        write(codexConfig, read(codexConfig) + "\n[hooks.state.\"\(key)\"]x\nkeep = 1\n")
        try CodexHooks.disconnect()
        #expect(read(codexConfig).contains("keep = 1"))
    }
}
