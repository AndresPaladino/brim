import Testing
import Foundation
import Darwin
@testable import Brim

/// The socket protocol: one JSON line in, maybe one JSON line out.
@MainActor
@Suite struct ClaudeBridgeTests {
    /// Feeds one line to the bridge's parser through a real connection and reports what came out.
    func receive(_ line: String) -> (events: [(ClaudeIncoming, Bool)], hook: SocketPair) {
        let bridge = ClaudeBridge(socketPath: "/tmp/unused-\(UUID().uuidString.prefix(6)).sock")
        var events: [(ClaudeIncoming, Bool)] = []
        bridge.onEvent = { e, reply in events.append((e, reply != nil)); reply?.pass() }
        let pair = SocketPair()
        let conn = ClaudeConnection(fd: pair.app)
        bridge.received(Data(line.utf8), host: nil, tty: nil, conn: conn)
        return (events, pair)
    }

    @Test func parsesAClaudeEvent() {
        let r = receive(#"{"hook_event_name":"Stop","session_id":"abc","cwd":"/x/brim","last_assistant_message":"hi"}"#)
        #expect(r.events.count == 1)
        let e = r.events[0].0
        #expect(e.agent == .claude && e.name == "Stop" && e.session == "abc" && e.string("last_assistant_message") == "hi")
        #expect(r.events[0].1 == false) // no reply object for Stop
        #expect(r.hook.reply() == "") // and the hook is released at once
    }

    @Test func permissionRequestsWait() {
        let r = receive(#"{"hook_event_name":"PermissionRequest","session_id":"a"}"#)
        #expect(r.events.first?.1 == true)
    }

    @Test func codexTagAndCodexQuestions() {
        let r = receive(#"{"brim_agent":"codex","hook_event_name":"PreToolUse","session_id":"a"}"#)
        #expect(r.events.first?.0.agent == .codex && r.events.first?.1 == true)
        let claudePre = receive(#"{"hook_event_name":"PreToolUse","session_id":"a"}"#)
        #expect(claudePre.events.first?.1 == false)
        let unknownAgent = receive(#"{"brim_agent":"gemini","hook_event_name":"Stop"}"#)
        #expect(unknownAgent.events.first?.0.agent == .claude)
    }

    @Test(arguments: ["", "not json", "[]", "{}", #"{"hook_event_name":5}"#, "null", #"{"session_id":"x"}"#, "\u{0}\u{1}"])
    func badLinesAreDropped(line: String) {
        let r = receive(line)
        #expect(r.events.isEmpty)
        #expect(r.hook.reply() == "")
    }

    @Test func missingFieldsDefault() {
        let r = receive(#"{"hook_event_name":"Stop"}"#)
        #expect(r.events.first?.0.session == "" && r.events.first?.0.cwd == "")
    }

    @Test func replyShapes() {
        let pair = SocketPair()
        ClaudeReply(ClaudeConnection(fd: pair.app)).allow(updatedInput: ["answers": ["Q": "A"]])
        let out = json(pair.reply() ?? "")
        let decision = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
        #expect((decision?["updatedInput"] as? [String: Any])?["answers"] as? [String: String] == ["Q": "A"])

        let codex = SocketPair()
        ClaudeReply(ClaudeConnection(fd: codex.app)).answerCodex(question: "Say \"hi\"?", labels: ["Yes", "No"])
        let reason = ((json(codex.reply() ?? "")["hookSpecificOutput"] as? [String: Any])?["permissionDecisionReason"] as? String) ?? ""
        #expect(reason.contains(#"Say "hi"?"#) && reason.contains("Yes, No"))
    }

    // MARK: Framing over a live connection

    func live(_ chunks: [String], closeAfter: Bool = false) async -> (lines: [String], closed: Bool) {
        let pair = SocketPair()
        let conn = ClaudeConnection(fd: pair.app)
        var lines: [String] = []
        var closed = false
        conn.onLine = { lines.append(String(decoding: $0, as: UTF8.self)) }
        conn.onClose = { closed = true }
        conn.start()
        for c in chunks {
            pair.send(c)
            try? await Task.sleep(for: .milliseconds(20))
        }
        if closeAfter { pair.closeHook() }
        _ = await eventually(timeout: 10) { !lines.isEmpty || closed }
        try? await Task.sleep(for: .milliseconds(30))
        if !closed { conn.finish(nil) }
        return (lines, closed)
    }

    @Test func lineSplitAcrossWrites() async {
        let r = await live([#"{"a":"#, #"1}"#, "\n"])
        #expect(r.lines == [#"{"a":1}"#])
    }

    @Test func onlyTheFirstLineCounts() async {
        let r = await live(["{\"a\":1}\n{\"b\":2}\n"])
        #expect(r.lines == [#"{"a":1}"#])
    }

    @Test func hookLeavingBeforeNewline() async {
        let r = await live([#"{"a":1}"#], closeAfter: true)
        #expect(r.lines.isEmpty && r.closed)
    }

    @Test func bigLineArrives() async {
        let big = "{\"x\":\"" + String(repeating: "a", count: 3 << 20) + "\"}"
        let pair = SocketPair()
        let conn = ClaudeConnection(fd: pair.app)
        var got = 0
        conn.onLine = { got = $0.count }
        conn.start()
        // Write from another thread: the socket buffer is smaller than the line.
        let fd = pair.hook
        Thread.detachNewThread { _ = (big + "\n").withCString { Darwin.write(fd, $0, strlen($0)) } }
        #expect(await eventually { got > 0 })
        #expect(got == big.utf8.count)
        conn.finish(nil)
    }

    // MARK: Listening socket

    @Test func listensAndRoundTrips() async throws {
        let dir = TempDir()
        let path = dir.file("c.sock").path
        let bridge = ClaudeBridge(socketPath: path)
        var names: [String] = []
        bridge.onEvent = { e, reply in names.append(e.name); reply?.allow() }
        bridge.start()
        defer { bridge.stop() }
        #expect(bridge.isRunning)
        var st = stat()
        #expect(stat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: path.utf8); raw[path.utf8.count] = 0 }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(ok == 0)
        _ = "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s\"}\n".withCString { write(fd, $0, strlen($0)) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let done = await eventually {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
            return n == 0
        }
        close(fd)
        #expect(done && names == ["PermissionRequest"], "done=\(done) names=\(names) out=\(out.count) errno=\(errno)")
        #expect(String(decoding: out, as: UTF8.self).contains("allow"))
    }

    @Test func stopRemovesTheSocket() {
        let dir = TempDir()
        let path = dir.file("c.sock").path
        let bridge = ClaudeBridge(socketPath: path)
        bridge.start()
        #expect(FileManager.default.fileExists(atPath: path))
        bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: path) && !bridge.isRunning)
    }

    /// A second Brim (or a test build) used to unlink the socket and bind its own, leaving the first
    /// listening on a file that no longer existed. Now it leaves a live socket alone.
    @Test func secondInstanceLeavesTheSocketAlone() {
        let dir = TempDir()
        let path = dir.file("c.sock").path
        let first = ClaudeBridge(socketPath: path), second = ClaudeBridge(socketPath: path)
        first.start()
        second.start()
        defer { first.stop() }
        #expect(first.isRunning && !second.isRunning, "both think they are listening")
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path), "the second one removed the first one's socket")
        #expect(ClaudeBridge.isListening(path))
    }

    /// Deleting the socket file (or its folder) used to silence every hook until the next launch.
    @Test func deletedSocketComesBack() async {
        let dir = TempDir()
        let path = dir.file("c.sock").path
        let bridge = ClaudeBridge(socketPath: path)
        bridge.start()
        defer { bridge.stop() }
        unlink(path)
        #expect(await eventually(timeout: 5) { ClaudeBridge.isListening(path) })
        #expect(bridge.isRunning)
    }

    @Test func deletedFolderComesBack() async throws {
        let dir = TempDir()
        let folder = dir.file("Brim")
        let path = folder.appendingPathComponent("c.sock").path
        let bridge = ClaudeBridge(socketPath: path)
        bridge.start()
        defer { bridge.stop() }
        try FileManager.default.removeItem(at: folder)
        #expect(await eventually(timeout: 5) { ClaudeBridge.isListening(path) })
        // And again, now watching the new folder.
        unlink(path)
        #expect(await eventually(timeout: 5) { ClaudeBridge.isListening(path) })
    }

    /// A file left by a crash doesn't accept connections, so the next start takes its place.
    @Test func staleSocketFileIsReplaced() throws {
        let dir = TempDir()
        let path = dir.file("c.sock").path
        let old = ClaudeBridge(socketPath: path)
        old.start()
        old.stop()
        // Recreate a dead socket file, as a crash would leave it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8 + [0]) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        #expect(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } } == 0)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path) && !ClaudeBridge.isListening(path))
        let bridge = ClaudeBridge(socketPath: path)
        bridge.start()
        defer { bridge.stop() }
        #expect(bridge.isRunning && ClaudeBridge.isListening(path))
    }

    /// Paths of 104 bytes or more don't fit in sockaddr_un. start() gives up without a word.
    @Test func longSocketPathFailsQuietly() {
        let long = "/tmp/" + String(repeating: "x", count: 110) + ".sock"
        let bridge = ClaudeBridge(socketPath: long)
        bridge.start()
        #expect(!bridge.isRunning)
    }
}
