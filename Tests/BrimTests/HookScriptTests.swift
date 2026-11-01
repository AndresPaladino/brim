import Testing
import Foundation
@testable import Brim

/// Runs Resources/claude-hook.sh and codex-hook.sh, as Claude Code and Codex do, against a real
/// ClaudeBridge listening in a temporary HOME.
@MainActor
@Suite struct HookScriptTests {
    final class Run: @unchecked Sendable {
        let process = Process()
        let out = Pipe()
        private var cached: String?
        var output: String {
            if let cached { return cached }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            cached = text
            return text
        }
    }

    let home = TempDir()
    var socketPath: String { home.url.appendingPathComponent("Library/Application Support/Brim/claude.sock").path }

    func run(_ script: String, input: String) -> Run {
        let r = Run()
        r.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        r.process.arguments = [Repo.resources.appendingPathComponent(script).path]
        r.process.environment = ["HOME": home.url.path, "PATH": "/usr/bin:/bin"]
        let inPipe = Pipe()
        r.process.standardInput = inPipe
        r.process.standardOutput = r.out
        r.process.standardError = FileHandle.nullDevice
        try! r.process.run()
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
        return r
    }

    func finished(_ r: Run) async -> Bool { await eventually { !r.process.isRunning } }

    @Test func claudeHookWithoutBrimDoesNothing() async {
        let r = run("claude-hook.sh", input: #"{"hook_event_name":"Stop"}"#)
        #expect(await finished(r))
        #expect(r.process.terminationStatus == 0 && r.output == "")
    }

    @Test func codexHookWithoutBrimPrintsEmptyObject() async {
        let r = run("codex-hook.sh", input: #"{"hook_event_name":"Stop"}"#)
        #expect(await finished(r))
        #expect(r.process.terminationStatus == 0 && r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }

    @Test func permissionRoundTrip() async throws {
        let bridge = ClaudeBridge(socketPath: socketPath)
        var got: [(ClaudeIncoming, ClaudeReply?)] = []
        bridge.onEvent = { got.append(($0, $1)) }
        bridge.start()
        defer { bridge.stop() }
        #expect(bridge.isRunning)

        // Pretty-printed input across several lines: the script must flatten it to one line.
        let r = run("claude-hook.sh", input: "{\n  \"hook_event_name\": \"PermissionRequest\",\n  \"session_id\": \"abc\",\n  \"tool_name\": \"Bash\"\n}\n")
        #expect(await eventually { !got.isEmpty })
        #expect(got.first?.0.session == "abc" && got.first?.1 != nil)
        #expect(r.process.isRunning) // waits for the answer
        got.first?.1?.allow()
        #expect(await finished(r))
        #expect(json(r.output)["hookSpecificOutput"] != nil)
        #expect(r.output.contains("\"allow\""))
    }

    @Test func passMeansClaudeAsksItself() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        bridge.onEvent = { _, reply in reply?.pass() }
        bridge.start()
        defer { bridge.stop() }
        let r = run("claude-hook.sh", input: #"{"hook_event_name":"PermissionRequest","session_id":"a"}"#)
        #expect(await finished(r))
        #expect(r.process.terminationStatus == 0 && r.output == "")
    }

    @Test func killedHookDismissesTheAlert() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        var gone = false
        var reply: ClaudeReply?
        bridge.onEvent = { _, r in reply = r; r?.onGone = { gone = true } }
        bridge.start()
        defer { bridge.stop() }
        let r = run("claude-hook.sh", input: #"{"hook_event_name":"PermissionRequest","session_id":"a"}"#)
        #expect(await eventually { reply != nil })
        r.process.terminate() // Claude Code gave up on the hook
        #expect(await eventually { gone })
    }

    @Test func codexEventsAreTagged() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        var agents: [Agent] = []
        bridge.onEvent = { e, reply in agents.append(e.agent); reply?.pass() }
        bridge.start()
        defer { bridge.stop() }
        let r = run("codex-hook.sh", input: #"  {"hook_event_name":"Stop","session_id":"x"}"#)
        #expect(await finished(r))
        #expect(agents == [.codex])
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }

    @Test func codexAnswerReachesCodex() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        bridge.onEvent = { _, reply in reply?.answerCodex(question: "Color?", labels: ["Blue"]) }
        bridge.start()
        defer { bridge.stop() }
        let r = run("codex-hook.sh", input: #"{"hook_event_name":"PreToolUse","session_id":"x","tool_name":"request_user_input"}"#)
        #expect(await finished(r))
        let out = json(r.output)["hookSpecificOutput"] as? [String: Any]
        #expect(out?["permissionDecision"] as? String == "deny")
    }

    /// The tag is inserted with a regex after the first "{". An empty object used to become
    /// {"brim_agent":"codex",}, which is invalid JSON. Reads the raw line the script sends.
    @Test(arguments: ["{}", " { }\n", #"{"hook_event_name":"Stop"}"#])
    func codexTagKeepsJSONValid(_ input: String) async throws {
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: socketPath.utf8 + [0]) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        #expect(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } } == 0)
        listen(fd, 1)
        let r = run("codex-hook.sh", input: input)
        let line = await Task.detached { () -> String in
            let c = accept(fd, nil, nil)
            defer { close(c) }
            var bytes: [UInt8] = [], byte: UInt8 = 0
            while read(c, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
            return String(decoding: bytes, as: UTF8.self)
        }.value
        #expect(await finished(r))
        let json = try #require(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "invalid JSON: \(line)")
        #expect(json["brim_agent"] as? String == "codex")
    }

    @Test func unicodeAndBigPayloads() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        var command = ""
        bridge.onEvent = { e, reply in command = (e.json["tool_input"] as? [String: Any])?["command"] as? String ?? ""; reply?.pass() }
        bridge.start()
        defer { bridge.stop() }
        let big = "echo '¿Qué tal? 日本語 🎵' " + String(repeating: "x", count: 2 << 20)
        let payload = jsonText(["hook_event_name": "PermissionRequest", "session_id": "u", "tool_input": ["command": big]])
        let r = run("claude-hook.sh", input: payload)
        #expect(await finished(r))
        #expect(command == big)
    }

    @Test func manyHooksAtOnce() async {
        let bridge = ClaudeBridge(socketPath: socketPath)
        var sessions = Set<String>()
        bridge.onEvent = { e, reply in sessions.insert(e.session); reply?.allow() }
        bridge.start()
        defer { bridge.stop() }
        let runs = (0..<20).map { run("claude-hook.sh", input: "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s\($0)\"}") }
        for r in runs { _ = await finished(r) }
        // Connections beyond the listen backlog are refused at once on macOS, and the hook takes that
        // as "Brim isn't running": the event would be lost without a trace.
        #expect(sessions.count == 20, "received \(sessions.count) of 20")
        #expect(runs.allSatisfy { $0.output.contains("allow") })
    }
}
