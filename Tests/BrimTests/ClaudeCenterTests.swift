import Testing
import Foundation
@testable import Brim

/// Claude Code and Codex alerts: which one shows, when it leaves, and what the hook gets back.
@MainActor
@Suite struct ClaudeCenterTests {

    // MARK: Permission requests

    @Test func allowFromTheNotch() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("npm test"))
        let n = try #require(h.notice)
        #expect(n.answerable && n.priority == 4 && n.project == "brim")
        guard case .permission(_, let detail, let code) = n.kind else { Issue.record("not a permission"); return }
        #expect(detail == "npm test" && code)
        #expect(hook.isOpen) // the hook waits

        h.center.answer(n.id, allow: true)
        let reply = try #require(hook.reply())
        #expect(json(reply) as NSDictionary == ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]] as NSDictionary)
        #expect(reply.hasSuffix("\n"))
        #expect(h.notice?.answered?.allow == true) // the critter reacts first
        h.clock.advance(by: 0.56)
        #expect(h.notice == nil)
    }

    @Test func denyFromTheNotch() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("rm -rf build"))
        h.center.answer(try #require(h.notice).id, allow: false)
        let decision = (json(try #require(hook.reply()))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect((decision?["message"] as? String)?.isEmpty == false)
    }

    @Test func answeringTwiceSendsOnce() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("ls"))
        let id = try #require(h.notice).id
        h.center.answer(id, allow: true)
        h.center.answer(id, allow: false)
        let reply = try #require(hook.reply())
        #expect(reply.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
        #expect(reply.contains("allow"))
    }

    @Test func approveOffPassesToTheTerminal() throws {
        let h = ClaudeHarness { $0.claudeApprove = false }
        let hook = h.request(Hook.bash("ls"))
        #expect(try #require(hook.reply()) == "") // closed without a decision: Claude Code asks itself
        #expect(h.notice != nil && h.notice?.answerable == false)
    }

    @Test func alertsOffPassesAndShowsNothing() throws {
        let h = ClaudeHarness { $0.claudeAlerts = false }
        let hook = h.request(Hook.bash("ls"))
        #expect(try #require(hook.reply()) == "")
        #expect(h.notice == nil)
        h.send("Stop", ["last_assistant_message": "Done"])
        #expect(h.notice == nil)
    }

    @Test func hookGoneDismissesTheAlert() async throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("ls"), live: true)
        #expect(h.notice != nil)
        hook.closeHook() // Claude Code killed the hook (answered in the terminal, or timed out)
        #expect(await eventually { h.notice == nil })
    }

    @Test func liveAnswerIsDelivered() async throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("ls"), live: true)
        h.center.answer(try #require(h.notice).id, allow: true)
        var reply: String?
        #expect(await eventually { reply = hook.reply(); return reply != nil })
        #expect(reply?.contains("allow") == true)
    }

    @Test func pendingRequestExpiresAfterThirtyMinutes() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.bash("ls"))
        h.clock.advance(by: 29 * 60)
        #expect(h.notice != nil)
        h.clock.advance(by: 61)
        #expect(h.notice == nil)
        #expect(try #require(hook.reply()) == "") // let go without answering
    }

    @Test func openAlertWaitsWhileOpen() {
        let h = ClaudeHarness()
        h.send("Stop", ["last_assistant_message": "All done."])
        h.open = true
        h.clock.advance(by: 60)
        #expect(h.notice != nil)
        h.open = false
        h.clock.advance(by: 2.1)
        #expect(h.notice == nil)
    }

    // MARK: Priority

    @Test func permissionBeatsEverything() {
        let h = ClaudeHarness()
        h.send("Stop", session: "a", ["last_assistant_message": "ok"])
        h.send("StopFailure", session: "b", ["error": "Rate limit"])
        h.request(Hook.bash("ls"), session: "c")
        h.send("Stop", session: "d", ["last_assistant_message": "newer but lower"])
        guard case .permission = h.kind else { Issue.record("expected permission, got \(String(describing: h.kind))"); return }
    }

    @Test func tiesGoToTheNewest() {
        let h = ClaudeHarness()
        h.send("Stop", session: "a", ["last_assistant_message": "first"])
        h.send("Stop", session: "b", ["last_assistant_message": "second"])
        #expect(h.notice?.session == "b")
    }

    @Test func whenTheTopLeavesTheNextShows() throws {
        let h = ClaudeHarness()
        h.send("StopFailure", session: "a", ["error": "boom"])
        h.request(Hook.bash("ls"), session: "b")
        h.center.answer(try #require(h.notice).id, allow: true)
        h.clock.advance(by: 0.6)
        guard case .error = h.kind else { Issue.record("expected the error to come back"); return }
    }

    // MARK: Lifetimes

    @Test(arguments: [("Stop", 9.0), ("StopFailure", 7.0)])
    func informationalAlertsLeave(event: String, seconds: Double) {
        let h = ClaudeHarness()
        h.send(event, ["last_assistant_message": "x"])
        h.clock.advance(by: seconds - 0.01)
        #expect(h.notice != nil)
        h.clock.advance(by: 0.02)
        #expect(h.notice == nil)
    }

    @Test func waitingLastsFifteenMinutes() {
        let h = ClaudeHarness()
        h.send("Notification", ["notification_type": "idle_prompt"])
        #expect(h.kind == .waiting)
        h.clock.advance(by: 15 * 60 - 1); #expect(h.notice != nil)
        h.clock.advance(by: 2); #expect(h.notice == nil)
    }

    @Test func idleAfterDoneIsRedundant() {
        let h = ClaudeHarness()
        h.send("Stop", ["last_assistant_message": "ok"])
        h.clock.advance(by: 10)
        h.send("Notification", ["notification_type": "idle_prompt"])
        #expect(h.notice == nil)
        // A new prompt rearms it.
        h.send("UserPromptSubmit")
        h.send("Notification", ["notification_type": "idle_prompt"])
        #expect(h.kind == .waiting)
    }

    @Test func otherNotificationsAreIgnored() {
        let h = ClaudeHarness()
        h.send("Notification", ["notification_type": "permission_prompt"])
        #expect(h.notice == nil)
    }

    @Test func newPromptClearsTheSession() {
        let h = ClaudeHarness()
        h.send("Stop", session: "a", ["last_assistant_message": "ok"])
        h.send("Stop", session: "b", ["last_assistant_message": "ok"])
        h.send("UserPromptSubmit", session: "b")
        #expect(h.notice?.session == "a")
        h.send("SessionEnd", session: "a")
        #expect(h.notice == nil)
    }

    @Test func doneReportsMinutes() {
        let h = ClaudeHarness()
        h.send("UserPromptSubmit")
        h.clock.advance(by: 5 * 60 + 10)
        h.send("Stop", ["last_assistant_message": "Built it.\n\nAll tests pass."])
        #expect(h.kind == .done(summary: "All tests pass.", minutes: 5))
        h.send("UserPromptSubmit")
        h.clock.advance(by: 30)
        h.send("Stop", ["last_assistant_message": "Quick."])
        #expect(h.kind == .done(summary: "Quick.", minutes: nil))
    }

    @Test func eventWithoutSessionStillWorks() {
        let h = ClaudeHarness()
        h.send("Stop", session: "", ["last_assistant_message": "ok"])
        #expect(h.notice != nil)
    }

    /// Two unrelated agents that both omit session_id used to share the "" key, so one dismissed the other.
    @Test func missingSessionIDsCollide() {
        let h = ClaudeHarness()
        h.request(Hook.bash("first"), session: "")
        h.send("UserPromptSubmit", session: "")
        #expect(h.notice != nil, "a prompt in some other session without an id dismissed the pending request")
        h.send("Stop", session: "", ["last_assistant_message": "ok"])
        guard case .permission = h.kind else { Issue.record("a Stop without an id replaced the request"); return }
    }

    // MARK: Questions

    @Test func questionAnsweredFromTheNotch() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.question(options: ["Pixel", "Smooth"]))
        let n = try #require(h.notice)
        #expect(n.listQuestion?.options.map(\.label) == ["Pixel", "Smooth"])
        h.center.choose(n.id, labels: ["Smooth"])
        let out = json(try #require(hook.reply()))
        let decision = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
        let updated = decision?["updatedInput"] as? [String: Any]
        #expect((updated?["answers"] as? [String: String]) == ["Which one?": "Smooth"])
        #expect((updated?["questions"] as? [Any])?.count == 1) // original questions kept
        #expect(h.notice?.chosen == ["Smooth"])
        h.clock.advance(by: 0.91)
        #expect(h.notice == nil)
    }

    @Test func multiSelectJoinsLabels() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.question(options: ["A", "B", "C"], multi: true))
        h.center.choose(try #require(h.notice).id, labels: ["A", "C"])
        #expect(try #require(hook.reply()).contains(#""Which one?":"A, C""#))
    }

    @Test func choosingNothingDoesNothing() throws {
        let h = ClaudeHarness()
        let hook = h.request(Hook.question())
        h.center.choose(try #require(h.notice).id, labels: [])
        #expect(hook.isOpen)
    }

    @Test func preToolUseThenPermissionRequestAttach() throws {
        let h = ClaudeHarness()
        h.send("PreToolUse", Hook.question())
        let first = try #require(h.notice)
        #expect(!first.answerable)
        let hook = h.request(Hook.question())
        #expect(h.notice?.id == first.id) // same alert, now answerable
        #expect(h.notice?.answerable == true)
        h.center.choose(first.id, labels: ["B"])
        #expect(try #require(hook.reply()).contains("\"B\""))
    }

    /// Two AskUserQuestion requests pending in one session (a subagent asking while the main agent asks).
    /// Attaching the second used to pass the first reply, whose onGone removed the entry being attached
    /// to, and then attach() indexed the shortened array.
    @Test func secondQuestionInTheSameSessionDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            await MainActor.run {
                let h = ClaudeHarness()
                h.request(Hook.question(options: ["A", "B"]))
                h.request(Hook.question("Second?", options: ["C", "D"]))
                _ = h.notice
            }
        }
    }

    /// Both stay open: the notch shows the newest, then the other once it's answered.
    @Test func secondQuestionWaitsBehindTheFirst() throws {
        let h = ClaudeHarness()
        let first = h.request(Hook.question(options: ["A", "B"]))
        let second = h.request(Hook.question("Second?", options: ["C", "D"]))
        #expect(first.reply() == nil)
        let n = try #require(h.notice)
        guard case .question(let q) = n.kind else { Issue.record("not a question"); return }
        #expect(q.text == "Second?" && n.answerable)
        h.center.choose(n.id, labels: ["D"])
        #expect(try #require(second.reply()).contains(#""Second?":"D""#))
        h.clock.advance(by: 1)
        let next = try #require(h.notice)
        guard case .question(let q1) = next.kind else { Issue.record("not a question"); return }
        #expect(q1.text == "Which one?")
        h.center.choose(next.id, labels: ["A"])
        #expect(try #require(first.reply()).contains(#""Which one?":"A""#))
    }

    /// Subagents ask in parallel: a second permission doesn't hand the first back to the terminal.
    @Test func twoPermissionsInOneSession() throws {
        let h = ClaudeHarness()
        let first = h.request(Hook.bash("first"))
        let second = h.request(Hook.bash("second"))
        #expect(first.reply() == nil)
        h.center.answer(try #require(h.notice).id, allow: true)
        #expect(try #require(second.reply()).contains("allow"))
        h.clock.advance(by: 1)
        guard case .permission(_, let detail, _) = h.kind else { Issue.record("first request gone"); return }
        #expect(detail == "first")
        h.center.answer(try #require(h.notice).id, allow: false)
        #expect(try #require(first.reply()).contains("deny"))
    }

    /// The turn ending still clears every open request of the session.
    @Test func stopClearsOpenRequests() throws {
        let h = ClaudeHarness()
        let first = h.request(Hook.bash("first"))
        h.request(Hook.bash("second"))
        h.send("Stop", ["last_assistant_message": "Done."])
        #expect(try #require(first.reply()) == "")
        guard case .done = h.kind else { Issue.record("no done alert"); return }
    }

    @Test func questionThatDoesNotFitLinksToTheApp() throws {
        let h = ClaudeHarness()
        h.request(Hook.question(options: ["1", "2", "3", "4", "5"]))
        let n = try #require(h.notice)
        #expect(n.listQuestion == nil)
        guard case .question(let q) = n.kind else { Issue.record("not a question"); return }
        #expect(!q.fitsNotch && q.options.count == 5)
    }

    @Test func autoAnswerPicksTheFirstOption() throws {
        ClaudeCenter.debugAutoAnswer = true
        defer { ClaudeCenter.debugAutoAnswer = false }
        let h = ClaudeHarness()
        let hook = h.request(Hook.question(options: ["First", "Second"]))
        #expect(try #require(hook.reply()).contains(#""Which one?":"First""#))
        #expect(h.notice == nil)
    }

    @Test func exitPlanModePassesAndShowsThePlan() throws {
        let h = ClaudeHarness()
        let hook = h.request(["tool_name": "ExitPlanMode", "tool_input": ["plan": "\n\n## Add tests to Brim\n\nDetails"]])
        #expect(try #require(hook.reply()) == "")
        guard case .permission(_, let detail, _) = h.kind else { Issue.record("no alert"); return }
        #expect(detail == "Add tests to Brim")
    }

    @Test func unknownRequestsPass() throws {
        let h = ClaudeHarness()
        let hook = h.request(["x": 1], event: "SomethingNew")
        #expect(try #require(hook.reply()) == "")
        #expect(h.notice == nil)
    }

    // MARK: Codex

    @Test func codexPermission() throws {
        let h = ClaudeHarness()
        let hook = h.request(["tool_name": "Bash", "tool_input": ["command": ["git", "status"]]], agent: .codex)
        let n = try #require(h.notice)
        #expect(n.agent == .codex)
        guard case .permission(_, let detail, true) = n.kind else { Issue.record("bad kind"); return }
        #expect(detail == "git status")
        h.center.answer(n.id, allow: true)
        #expect(try #require(hook.reply()).contains("allow"))
    }

    @Test func codexQuestionIsAnsweredByBlocking() throws {
        let h = ClaudeHarness()
        let hook = h.request(["tool_name": "request_user_input",
            "tool_input": ["questions": [["question": "Favorite color?", "options": [["label": "Blue", "description": ""], ["label": "Red", "description": ""]]]]]],
            event: "PreToolUse", agent: .codex)
        let n = try #require(h.notice)
        h.center.choose(n.id, labels: ["Blue"])
        let out = json(try #require(hook.reply()))["hookSpecificOutput"] as? [String: Any]
        #expect(out?["hookEventName"] as? String == "PreToolUse")
        #expect(out?["permissionDecision"] as? String == "deny")
        #expect((out?["permissionDecisionReason"] as? String)?.contains("Blue") == true)
    }

    @Test func codexAsyncQuestionWithPlainOptions() throws {
        let h = ClaudeHarness()
        h.request(["tool_name": "request_user_input_async",
            "tool_input": ["questions": [["title": "Deploy now?", "options": ["Yes", "No"]]]]], event: "PreToolUse", agent: .codex)
        guard case .question(let q) = h.kind else { Issue.record("no question"); return }
        #expect(q.text == "Deploy now?" && q.options.map(\.label) == ["Yes", "No"])
    }

    @Test func codexOffDoesNotAffectClaude() throws {
        let h = ClaudeHarness { $0.codexAlerts = false }
        let codex = h.request(["tool_name": "Bash", "tool_input": ["command": "ls"]], agent: .codex)
        #expect(try #require(codex.reply()) == "")
        #expect(h.notice == nil)
        h.send("Stop", ["last_assistant_message": "ok"])
        #expect(h.notice != nil)
    }

    @Test func codexFocusLetsGoOfTheRequest() throws {
        let h = ClaudeHarness()
        let hook = h.request(["tool_name": "Bash", "tool_input": ["command": "ls"]], agent: .codex)
        h.center.focus(try #require(h.notice).id)
        #expect(try #require(hook.reply()) == "") // Codex shows its own prompt once the hook returns
        #expect(h.notice == nil)
    }

    @Test func focusDismissesInformationalAlerts() throws {
        let h = ClaudeHarness()
        h.send("Stop", ["last_assistant_message": "ok"])
        h.center.focus(try #require(h.notice).id)
        #expect(h.notice == nil)
        let hook = h.request(Hook.bash("ls"))
        h.center.focus(try #require(h.notice).id)
        #expect(h.notice != nil && hook.isOpen) // a Claude permission stays until answered
    }

    // MARK: Memory

    /// Every session that ever finished stays in turnStart / announcedDone. Sessions without SessionEnd
    /// (killed terminals) are never cleaned up. Measured indirectly: no API to read them, so this
    /// documents the growth with a large run and checks nothing crashes.
    @Test func manySessionsDoNotPileUpAlerts() {
        let h = ClaudeHarness()
        for i in 0..<5000 {
            h.send("UserPromptSubmit", session: "s\(i)")
            h.send("Stop", session: "s\(i)", ["last_assistant_message": "ok"])
            h.clock.advance(by: 10)
        }
        h.clock.advance(by: 10)
        #expect(h.notice == nil)
        #expect(h.clock.pending == 0)
    }
}
