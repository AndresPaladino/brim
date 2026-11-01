import Testing
import Foundation
@testable import Brim

/// Seeded random input. BRIM_FUZZ sets the iterations (500 by default, 10000 in `scripts/test.sh all`);
/// BRIM_SEED replays a failing run.
struct Fuzz: RandomNumberGenerator {
    static let iterations = Int(ProcessInfo.processInfo.environment["BRIM_FUZZ"] ?? "") ?? 500
    static let seed = UInt64(ProcessInfo.processInfo.environment["BRIM_SEED"] ?? "") ?? 0xB121_0001
    private var state: UInt64
    init(_ salt: UInt64 = 0) { state = Self.seed &+ salt }
    mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }

    mutating func text(maxLength: Int = 40) -> String {
        let pieces = ["a", "Z", " ", "\n", "\n\n", "```", "**", "[x](y)", "- ", "# ", "é", "ñ", "日本", "🎵", "\u{202E}", "\u{0}", "\"", "\\", "%@", "%d", "--", "+", "*** Add File: f.swift"]
        return (0..<Int.random(in: 0...maxLength, using: &self)).map { _ in pick(pieces) }.joined()
    }

    mutating func value(depth: Int = 0) -> Any {
        switch Int.random(in: 0..<(depth > 2 ? 4 : 7), using: &self) {
        case 0: return text()
        case 1: return Int.random(in: -5...5, using: &self)
        case 2: return chance(0.5)
        case 3: return NSNull()
        case 4: return (0..<Int.random(in: 0...3, using: &self)).map { _ in value(depth: depth + 1) }
        default: return Dictionary(uniqueKeysWithValues: (0..<Int.random(in: 0...3, using: &self)).map { i in ("k\(i)", value(depth: depth + 1)) })
        }
    }
}

@MainActor
@Suite struct FuzzTests {
    static let events = ["PermissionRequest", "PreToolUse", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Notification", "Unknown"]
    static let tools = ["Bash", "Edit", "MultiEdit", "Write", "WebFetch", "WebSearch", "NotebookEdit", "ExitPlanMode", "AskUserQuestion",
                        "mcp__srv__do_it", "apply_patch", "request_user_input", "request_user_input_async", "Weird"]

    /// Random Claude and Codex traffic, answers, clicks and time. Every hook must be let go eventually,
    /// and the notch must end up empty.
    @Test func claudeTraffic() {
        var r = Fuzz(1)
        let h = ClaudeHarness { $0.claudeApprove = r.chance(0.8) }
        var hooks: [SocketPair] = []
        for _ in 0..<Fuzz.iterations {
            let agent: Agent = r.chance(0.25) ? .codex : .claude
            let session = "s\(Int.random(in: 0..<4, using: &r))"
            let event = r.pick(Self.events)
            let tool = r.pick(Self.tools)
            var extra: [String: Any] = ["tool_name": tool, "notification_type": r.pick(["idle_prompt", "other"]),
                                        "last_assistant_message": r.text(maxLength: 80), "error": r.text()]
            if tool == "AskUserQuestion" || tool.hasPrefix("request_user_input") {
                extra["tool_input"] = ["questions": (0..<Int.random(in: 0...2, using: &r)).map { _ in
                    ["question": r.text(), "multiSelect": r.chance(0.5), "options": (0..<Int.random(in: 0...6, using: &r)).map { _ in r.chance(0.8) ? ["label": r.text(maxLength: 6), "description": r.text()] as Any : r.text() as Any }]
                }]
            } else {
                extra["tool_input"] = r.chance(0.7) ? ["command": r.text(maxLength: 60), "file_path": "/x/\(r.text(maxLength: 5))", "old_string": r.text(), "new_string": r.text(), "url": r.text(), "plan": r.text(), "description": r.text()] : r.value()
            }
            if event == "PermissionRequest" || (agent == .codex && event == "PreToolUse") {
                hooks.append(h.request(extra, event: event, session: session, agent: agent))
            } else {
                h.send(event, session: session, agent: agent, extra)
            }
            // Act on whatever shows.
            if let n = h.notice, r.chance(0.3) {
                switch Int.random(in: 0..<4, using: &r) {
                case 0: h.center.answer(n.id, allow: r.chance(0.5))
                case 1: h.center.choose(n.id, labels: n.listQuestion.map { q in q.options.filter { _ in r.chance(0.5) }.map(\.label) } ?? ["x"])
                case 2: h.center.focus(n.id)
                default: h.open.toggle()
                }
            }
            h.clock.advance(by: r.pick([0, 0.1, 1, 5, 60]))
        }
        h.open = false
        h.clock.advance(by: 31 * 60)
        #expect(h.notice == nil, "an alert outlived every timeout")
        let hanging = hooks.filter { $0.reply() == nil }.count
        #expect(hanging == 0, "\(hanging) hooks were never let go")
        #expect(h.clock.pending == 0)
    }

    /// Random alerts, key presses, music and clicks on the island. Invariants at every step, and
    /// everything back at rest once the timers run out.
    @Test func islandTraffic() {
        var r = Fuzz(2)
        let clock = ManualScheduler()
        let model = IslandModel()
        let p = IslandPresenter(model: model, prefs: makePreferences(), scheduler: clock)
        let screen = IslandScreen(geometry: IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true))
        var volume: Float = 0.5, muted = false
        for _ in 0..<(Fuzz.iterations * 4) {
            switch Int.random(in: 0..<9, using: &r) {
            case 0:
                let key = r.pick([MediaKey.volumeUp, .volumeDown, .mute])
                let c = IslandPresenter.volumeChange(key, volume: volume, muted: muted, fine: r.chance(0.3))
                volume = c.setVolume ?? volume; muted = c.setMuted ?? muted
                #expect((0...1).contains(volume))
                #expect(!(volume > 0 && key == .volumeUp && muted), "volume up left it muted")
                p.showHUD(HUDState(kind: .volume, level: Double(c.level), muted: c.muted), bump: c.atLimit)
            case 1: p.showDevice(AudioDeviceEvent(name: r.text(), status: .connected, battery: r.chance(0.5) ? Int.random(in: 0...100, using: &r) : nil, visual: .symbol("airpods")))
            case 2: p.power(r.pick([.plugged(percent: 50, alreadyFull: false), .unplugged(percent: 40), .full(percent: 80), .low(percent: 10)]))
            case 3: p.boop()
            case 4: p.nowPlayingChanged(r.chance(0.2) ? nil : track(r.pick(["A", "B"]), playing: r.chance(0.6), elapsed: Double.random(in: 0...200, using: &r), at: clock.now))
            case 5: p.perform(r.pick([.togglePlayPause, .next, .previous, .seek(Double.random(in: 0...200, using: &r))]))
            case 6: screen.expanded.toggle(); screen.expandedClaude = r.chance(0.5)
            case 7: screen.fullscreen = r.chance(0.2)
            default: break
            }
            let m = screen.mode(of: model)
            if model.hud != nil { #expect(m == .hud) }
            if screen.fullscreen { #expect(m != .media && m != .compact) }
            #expect(model.stretch == 0 || model.stretch == IslandPresenter.bumpStretch)
            if let np = model.nowPlaying { #expect(np.position(at: clock.now) >= 0) }
            clock.advance(by: r.pick([0, 0.05, 0.5, 2, 10]))
        }
        p.nowPlayingChanged(nil)
        clock.drain()
        #expect(model.hud == nil && model.device == nil && model.charge == nil && model.boop == nil && model.stretch == 0 && !model.mediaVisible)
        #expect(clock.pending == 0)
    }

    @Test func textNeverCrashesOrShowsFences() {
        var r = Fuzz(3)
        for _ in 0..<(Fuzz.iterations * 4) {
            let message = r.text(maxLength: 120)
            let s = ClaudeCenter.summary(of: message)
            #expect(!s.contains("\n"))
            #expect(s == s.trimmingCharacters(in: .whitespaces))
            let input = r.value() as? [String: Any] ?? ["command": r.text()]
            _ = ClaudeCenter.describe(tool: r.pick(Self.tools), input: input)
            _ = ClaudeCenter.describeCodex(tool: r.pick(Self.tools), input: input)
            _ = ClaudeCenter.question(input)
            _ = ClaudeLayout.questionLines(r.text(maxLength: 200))
        }
    }

    @Test func bridgeLinesNeverCrash() {
        var r = Fuzz(4)
        let bridge = ClaudeBridge(socketPath: "/tmp/unused.sock")
        var events = 0
        bridge.onEvent = { _, reply in events += 1; reply?.pass() }
        for _ in 0..<Fuzz.iterations {
            var object = r.value() as? [String: Any] ?? [:]
            if r.chance(0.6) { object["hook_event_name"] = r.pick(Self.events) }
            if r.chance(0.3) { object["brim_agent"] = r.pick(["codex", "claude", "x", ""]) }
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            if r.chance(0.2), !data.isEmpty { data.remove(at: Int.random(in: 0..<data.count, using: &r)) } // corrupt
            let pair = SocketPair()
            bridge.received(data, host: nil, tty: nil, conn: ClaudeConnection(fd: pair.app))
            #expect(pair.reply() != nil, "connection left open for a line that isn't a request")
        }
        #expect(events > 0)
    }

    @Test func lineParserGarbage() {
        var r = Fuzz(5)
        let parser = LineParser()
        var parsed = 0
        for _ in 0..<Fuzz.iterations {
            var chunk = Data((0..<Int.random(in: 0...64, using: &r)).map { _ in UInt8.random(in: 0...255, using: &r) })
            if r.chance(0.3) { chunk += Data("{\"active\":true,\"title\":\"\(r.text(maxLength: 8).replacingOccurrences(of: "\"", with: ""))\"}\n".utf8) }
            parsed += parser.feed(chunk).count
        }
        #expect(parsed >= 0)
    }
}
