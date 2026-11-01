import Foundation
@testable import Brim

/// A ClaudeCenter wired to a manual clock and test preferences. Events go straight to the center,
/// as if they came through the socket; requests get a real socket pair so replies can be read.
@MainActor
final class ClaudeHarness {
    let clock = ManualScheduler()
    let model = IslandModel()
    let prefs: Preferences
    let bridge: ClaudeBridge
    let center: ClaudeCenter
    private let dir = TempDir()
    var open = false

    init(_ configure: (Preferences) -> Void = { _ in }) {
        prefs = makePreferences(configure)
        bridge = ClaudeBridge(socketPath: dir.file("s.sock").path)
        center = ClaudeCenter(model: model, bridge: bridge, prefs: prefs, scheduler: clock)
        center.isOpen = { [unowned self] in self.open }
    }

    func incoming(_ name: String, session: String = "s1", agent: Agent = .claude, cwd: String = "/Users/me/Projects/brim",
                  _ extra: [String: Any] = [:]) -> ClaudeIncoming {
        var json: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": cwd]
        json.merge(extra) { _, new in new }
        if agent == .codex { json["brim_agent"] = "codex" }
        return ClaudeIncoming(agent: agent, name: name, session: session, cwd: cwd, json: json, host: nil, tty: nil)
    }

    /// An event that doesn't wait for an answer.
    func send(_ name: String, session: String = "s1", agent: Agent = .claude, _ extra: [String: Any] = [:]) {
        bridge.onEvent?(incoming(name, session: session, agent: agent, extra), nil)
    }

    /// An event whose hook waits for an answer. Read the answer from the returned socket.
    /// `live` starts the read source, so the app notices the hook leaving (needs `await eventually`).
    @discardableResult
    func request(_ extra: [String: Any], event name: String = "PermissionRequest", session: String = "s1", agent: Agent = .claude,
                 live: Bool = false) -> SocketPair {
        let pair = SocketPair()
        let conn = ClaudeConnection(fd: pair.app)
        if live { conn.start() }
        bridge.onEvent?(incoming(name, session: session, agent: agent, extra), ClaudeReply(conn))
        return pair
    }

    var notice: ClaudeNotice? { model.claude }
    var kind: ClaudeNotice.Kind? { model.claude?.kind }
}

enum Hook {
    static func bash(_ command: String) -> [String: Any] { ["tool_name": "Bash", "tool_input": ["command": command]] }
    static func question(_ text: String = "Which one?", options: [String] = ["A", "B"], multi: Bool = false, count: Int = 1) -> [String: Any] {
        let q: [String: Any] = ["question": text, "header": "H", "multiSelect": multi,
                                "options": options.map { ["label": $0, "description": "about \($0)"] }]
        return ["tool_name": "AskUserQuestion", "tool_input": ["questions": Array(repeating: q, count: count)]]
    }
}
