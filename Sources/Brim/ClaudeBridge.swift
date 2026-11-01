import AppKit
import Darwin
import SwiftUI

/// Debug commands (scripts/dev/brimctl) and click logging. Off unless enabled with:
///   defaults write com.andrespaladino.brim debugTools -bool YES
enum DebugTools {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugTools") }
}

/// Who sent the event. Codex's hook (Resources/codex-hook.sh) tags its events with "brim_agent".
enum Agent: String {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    var tint: Color { self == .claude ? CritterDrawing.clay : PomponDrawing.lavender }
}

/// An event from Resources/claude-hook.sh or Resources/codex-hook.sh.
struct ClaudeIncoming {
    let agent: Agent
    let name: String
    let session: String
    let cwd: String
    let json: [String: Any]
    /// The app hosting the session (a terminal or VS Code).
    let host: NSRunningApplication?
    /// The session's terminal ("/dev/ttys003"), to find its exact tab in iTerm or Terminal.
    let tty: String?

    func string(_ key: String) -> String? { json[key] as? String }
    var project: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd.isEmpty || (cwd as NSString).standardizingPath == (home as NSString).standardizingPath { return "~" }
        return (cwd as NSString).lastPathComponent
    }
}

/// Receives Claude Code and Codex hook events over a local Unix socket.
@MainActor
final class ClaudeBridge {
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Brim/claude.sock").path

    /// `reply` is only set for permission requests, where the hook waits for an answer.
    var onEvent: ((ClaudeIncoming, ClaudeReply?) -> Void)?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ClaudeConnection] = [:]

    var isRunning: Bool { listenFD >= 0 }

    func start() {
        guard !isRunning else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel(); acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
        connections.values.forEach { $0.finish(nil) }
        connections.removeAll()
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let (host, tty) = Self.hostApp(peerOf: fd)
            let conn = ClaudeConnection(fd: fd)
            let key = ObjectIdentifier(conn)
            connections[key] = conn
            conn.onLine = { [weak self] line in self?.received(line, host: host, tty: tty, conn: conn) }
            conn.onClose = { [weak self] in self?.connections[key] = nil }
            conn.start()
        }
    }

    private func received(_ line: Data, host: NSRunningApplication?, tty: String?, conn: ClaudeConnection) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let name = json["hook_event_name"] as? String else { conn.finish(nil); return }
        let agent = Agent(rawValue: json["brim_agent"] as? String ?? "") ?? .claude
        let event = ClaudeIncoming(agent: agent, name: name, session: json["session_id"] as? String ?? "",
                                   cwd: json["cwd"] as? String ?? "", json: json, host: host, tty: tty)
        // Codex questions arrive as PreToolUse and wait for an answer too.
        if name == "PermissionRequest" || (agent == .codex && name == "PreToolUse") {
            onEvent?(event, ClaudeReply(conn))
        } else {
            conn.finish(nil)
            onEvent?(event, nil)
        }
    }

    /// Walks up the hook's parent processes to the first regular app. The first controlling
    /// terminal found on the way is the session's.
    private static func hostApp(peerOf fd: Int32) -> (NSRunningApplication?, String?) {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len) == 0 else { return (nil, nil) }
        var tty: String?
        for _ in 0..<40 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return (app, tty) }
            guard let info = processInfo(pid) else { return (nil, tty) }
            if tty == nil, info.kp_eproc.e_tdev != -1, let name = devname(info.kp_eproc.e_tdev, S_IFCHR) {
                tty = "/dev/" + String(cString: name)
            }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1 else { return (nil, tty) }
            pid = parent
        }
        return (nil, tty)
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

/// Answer to a permission request, sent once. `onGone` fires if the agent stops waiting.
/// Claude Code and Codex read the same shape.
@MainActor
final class ClaudeReply {
    private let conn: ClaudeConnection
    var onGone: (() -> Void)? {
        didSet { conn.onClose = { [weak self, previous = conn.onClose] in previous?(); self?.onGone?() } }
    }

    fileprivate init(_ conn: ClaudeConnection) { self.conn = conn }

    func allow() { send(["behavior": "allow"]) }
    /// Allow with modified input. This is how AskUserQuestion gets answered (questions plus `answers`).
    func allow(updatedInput: [String: Any]) { send(["behavior": "allow", "updatedInput": updatedInput]) }
    func deny() { send(["behavior": "deny", "message": "The user denied this from the notch (Brim)."]) }
    /// No decision: Claude Code shows its own prompt.
    func pass() { conn.finish(nil) }

    /// Answers a Codex question. Codex hooks can't fill in the answer, so the call is blocked with the
    /// answer as the reason, which the model reads as the result (tested: it continues with it).
    func answerCodex(question: String, labels: [String]) {
        let reason = "The user answered this question from the notch (Brim) instead of the Codex window. "
            + "Their answer to \"\(question)\" is: \(labels.joined(separator: ", ")). Continue with that answer; don't ask again."
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]]
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
        conn.finish(data + Data("\n".utf8))
    }

    private func send(_ decision: [String: Any]) {
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
        conn.finish(data + Data("\n".utf8))
    }
}

/// One hook connection: reads one JSON line, optionally replies, then closes.
@MainActor
final class ClaudeConnection {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var gotLine = false
    private var closed = false
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32) { self.fd = fd }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        // Close the descriptor only after GCD is done with it.
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                guard !gotLine else { continue }
                buffer.append(contentsOf: chunk[0..<n])
                // No Claude Code event gets this big.
                if buffer.count > 32 << 20 { finish(nil); return }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    gotLine = true
                    let line = buffer[..<nl]
                    buffer = Data()
                    onLine?(Data(line))
                    if closed { return }
                }
            } else if n == 0 {
                finish(nil) // the hook went away
                return
            } else {
                return // EAGAIN
            }
        }
    }

    func finish(_ data: Data?) {
        guard !closed else { return }
        closed = true
        if let data { data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) } }
        if let source { source.cancel() } else { close(fd) }
        source = nil
        // `onLine` captures this connection; releasing the closures breaks the retain cycle.
        let onClose = self.onClose
        self.onLine = nil
        self.onClose = nil
        onClose?()
    }
}

/// Watches the session transcript while a request is pending. When the result of that exact tool call
/// shows up, it was answered in the terminal or VS Code. Claude often runs several tools at once, so a
/// result for another call doesn't count.
@MainActor
final class TranscriptWatch {
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64
    private var partial = Data()
    private let path: String
    private let toolUseID: String?

    /// PermissionRequest events have no tool_use_id, so it is looked up by tool name and input.
    init?(path: String, toolUseID: String?, tool: String, input: [String: Any], onAnswered: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.path = path
        offset = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        self.toolUseID = toolUseID ?? Self.findToolUse(in: path, size: offset, tool: tool, input: input)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Don't capture `source` in its own handler, or they retain each other.
                guard let self, let flags = self.source?.data else { return }
                if flags.contains(.delete) || flags.contains(.rename) { self.cancel(); return }
                if self.newLinesAnswer() { self.cancel(); onAnswered() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func newLinesAnswer() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        partial.append(data)
        // Complete lines only; the rest waits for the next write.
        guard let lastNL = partial.lastIndex(of: 0x0A) else { return false }
        let complete = partial[..<lastNL]
        partial = Data(partial[partial.index(after: lastNL)...])
        guard complete.range(of: Data("\"tool_result\"".utf8)) != nil else { return false }
        guard let id = toolUseID else { return true }
        return complete.split(separator: 0x0A).contains { line in
            Self.contentItems(of: Data(line)).contains { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == id }
        }
    }

    private static func findToolUse(in path: String, size: UInt64, tool: String, input: [String: Any]) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > 512 << 10 ? size - (512 << 10) : 0)
        let data = handle.readDataToEndOfFile()
        let wanted = NSDictionary(dictionary: input)
        for line in data.split(separator: 0x0A).reversed() {
            for item in contentItems(of: Data(line)).reversed()
            where item["type"] as? String == "tool_use" && item["name"] as? String == tool {
                if let given = item["input"] as? [String: Any], NSDictionary(dictionary: given).isEqual(to: wanted as! [AnyHashable: Any]) {
                    return item["id"] as? String
                }
            }
        }
        return nil
    }

    private static func contentItems(of line: Data) -> [[String: Any]] {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    func cancel() { source?.cancel(); source = nil }
}
