import AppKit
import SwiftUI

/// Turns Claude Code and Codex hook events into notch alerts and picks which one shows:
/// permission > question > error > waiting > finished.
@MainActor
final class ClaudeCenter {
    private let bridge: ClaudeBridge
    private let model: IslandModel
    private let prefs: Preferences
    private let scheduler: Scheduler

    var onChange: (() -> Void)?
    /// While an alert is open on screen it doesn't time out.
    var isOpen: () -> Bool = { false }

    private struct Entry {
        var notice: ClaudeNotice
        var reply: ClaudeReply?
        var watch: TranscriptWatch?
        var hide: Scheduled?
        var host: NSRunningApplication?
        var tty: String?
        /// Original tool input, needed to answer AskUserQuestion.
        var input: [String: Any] = [:]
    }
    private var entries: [Entry] = []
    private var turnStart: [String: Date] = [:]
    /// Sessions that already showed "Done". The idle notification a minute later would be redundant.
    private var announcedDone: Set<String> = []

    static var debugAutoAnswer = false
    private static let doneDuration: TimeInterval = 9
    private static let errorDuration: TimeInterval = 7
    private static let waitingDuration: TimeInterval = 15 * 60
    private static let pendingLimit: TimeInterval = 30 * 60

    init(model: IslandModel, bridge: ClaudeBridge? = nil, prefs: Preferences? = nil, scheduler: Scheduler? = nil) {
        self.model = model
        self.bridge = bridge ?? ClaudeBridge()
        self.prefs = prefs ?? .shared
        self.scheduler = scheduler ?? MainScheduler.shared
        self.bridge.onEvent = { [weak self] event, reply in self?.handle(event, reply: reply) }
    }

    func refresh() {
        if prefs.codexAlerts { CodexHooks.upgradeIfNeeded() }
        if prefs.claudeAlerts || prefs.codexAlerts { bridge.start() } else { stopAll() }
        entries.filter { !($0.notice.agent == .codex ? prefs.codexAlerts : prefs.claudeAlerts) }.forEach { remove($0.notice.id, publish: false) }
        publish()
    }

    private func stopAll() {
        bridge.stop()
        entries.forEach { $0.watch?.cancel(); $0.hide?.cancel() }
        entries.removeAll()
        publish()
    }

    // MARK: - Events

    private func handle(_ event: ClaudeIncoming, reply: ClaudeReply?) {
        // Without an id, an event is its own session: two agents that both omit it would otherwise
        // dismiss each other's alerts.
        var event = event
        if event.session.isEmpty { event.session = "unknown-\(UUID().uuidString)" }
        let enabled = event.agent == .codex ? prefs.codexAlerts : prefs.claudeAlerts
        guard enabled else { reply?.pass(); return }
        if event.agent == .codex { handleCodex(event, reply: reply); return }
        switch event.name {
        case "UserPromptSubmit":
            turnStart[event.session] = scheduler.now
            announcedDone.remove(event.session)
            dismiss(session: event.session)
        case "SessionEnd":
            turnStart[event.session] = nil
            announcedDone.remove(event.session)
            dismiss(session: event.session)
        case "PermissionRequest":
            let tool = event.string("tool_name") ?? ""
            let input = event.json["tool_input"] as? [String: Any] ?? [:]
            switch tool {
            case "AskUserQuestion":
                // Debug: answer with the first option (brimctl autoanswer on).
                if Self.debugAutoAnswer, let reply, let questions = input["questions"] as? [[String: Any]] {
                    var answers: [String: String] = [:]
                    for q in questions {
                        if let text = q["question"] as? String, let first = (q["options"] as? [[String: Any]])?.first?["label"] as? String { answers[text] = first }
                    }
                    var updated = input
                    updated["answers"] = answers
                    reply.allow(updatedInput: updated)
                    return
                }
                // Keep the connection open to answer from the notch. The question also shows in the
                // terminal; whichever answers first wins.
                var reply = reply
                if !prefs.claudeApprove { reply?.pass(); reply = nil }
                if let i = entries.firstIndex(where: { $0.notice.session == event.session && $0.notice.priority == 3 && $0.reply == nil }) {
                    // The alert already came through PreToolUse. A question that already has a
                    // connection is a different one: it gets its own alert below.
                    if let reply { attach(reply, input: input, to: i) }
                } else {
                    add(event, Self.question(input), reply: reply, input: input, watch: true)
                }
            case "ExitPlanMode":
                reply?.pass()
                let plan = (input["plan"] as? String ?? "").split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let detail = plan.map { String($0).replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) } ?? ""
                add(event, .permission(title: Strings.claudePlan, detail: detail, code: false), watch: true)
            default:
                let (title, detail, code) = Self.describe(tool: tool, input: input)
                var reply = reply
                if !prefs.claudeApprove { reply?.pass(); reply = nil }
                add(event, .permission(title: title, detail: detail, code: code), reply: reply, watch: true)
            }
        case "PreToolUse" where event.string("tool_name") == "AskUserQuestion":
            add(event, Self.question(event.json["tool_input"] as? [String: Any] ?? [:]), watch: true)
        case "Stop":
            let minutes = turnStart.removeValue(forKey: event.session).map { Int(scheduler.now.timeIntervalSince($0) / 60) }
            announcedDone.insert(event.session)
            add(event, .done(summary: Self.summary(of: event.string("last_assistant_message") ?? ""), minutes: (minutes ?? 0) >= 1 ? minutes : nil),
                hideAfter: Self.doneDuration)
        case "StopFailure":
            turnStart[event.session] = nil
            let message = event.string("last_assistant_message") ?? event.string("error") ?? ""
            add(event, .error(message), hideAfter: Self.errorDuration)
        case "Notification" where event.string("notification_type") == "idle_prompt":
            guard !entries.contains(where: { $0.notice.session == event.session }),
                  !announcedDone.contains(event.session) else { return }
            add(event, .waiting, hideAfter: Self.waitingDuration)
        default:
            reply?.pass()
        }
    }

    /// Codex sends fewer events: no questions, idle notices or failures, and its approval prompt
    /// only appears after this hook lets go (see `focus`).
    private func handleCodex(_ event: ClaudeIncoming, reply: ClaudeReply?) {
        switch event.name {
        case "UserPromptSubmit":
            turnStart[event.session] = scheduler.now
            dismiss(session: event.session)
        case "PermissionRequest":
            let input = event.json["tool_input"] as? [String: Any] ?? [:]
            let (title, detail, code) = Self.describeCodex(tool: event.string("tool_name") ?? "", input: input)
            var reply = reply
            if !prefs.claudeApprove { reply?.pass(); reply = nil }
            add(event, .permission(title: title, detail: detail, code: code), reply: reply, hideAfter: reply == nil ? Self.doneDuration : Self.pendingLimit)
        case "PreToolUse" where (event.string("tool_name") ?? "").hasPrefix("request_user_input"):
            // request_user_input has Claude's shape; request_user_input_async uses "title" and plain-text options.
            let input = event.json["tool_input"] as? [String: Any] ?? [:]
            let kind = Self.question(input)
            var reply = reply
            if !prefs.claudeApprove || (Self.questionFits(kind) == false) { reply?.pass(); reply = nil }
            add(event, kind, reply: reply, hideAfter: Self.pendingLimit)
        case "Stop":
            let minutes = turnStart.removeValue(forKey: event.session).map { Int(scheduler.now.timeIntervalSince($0) / 60) }
            add(event, .done(summary: Self.summary(of: event.string("last_assistant_message") ?? ""), minutes: (minutes ?? 0) >= 1 ? minutes : nil),
                hideAfter: Self.doneDuration)
        default:
            reply?.pass()
        }
    }

    static func isRequest(_ kind: ClaudeNotice.Kind) -> Bool {
        switch kind {
        case .permission, .question: true
        default: false
        }
    }

    static func questionFits(_ kind: ClaudeNotice.Kind) -> Bool {
        if case .question(let q) = kind { return q.fitsNotch }
        return false
    }

    /// The transcript where the result will appear: the session's, or a subagent's
    /// (<session>/subagents/agent-<id>.jsonl).
    static func transcript(of event: ClaudeIncoming) -> String? {
        if let path = event.string("agent_transcript_path") { return (path as NSString).expandingTildeInPath }
        guard let main = event.string("transcript_path") else { return nil }
        if let agent = event.string("agent_id"), !agent.isEmpty {
            let name = agent.hasPrefix("agent-") ? agent : "agent-\(agent)"
            let sub = ((main as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("\(event.session)/subagents/\(name).jsonl")
            if FileManager.default.fileExists(atPath: sub) { return sub }
        }
        return main
    }

    static func question(_ input: [String: Any]) -> ClaudeNotice.Kind {
        let all = input["questions"] as? [[String: Any]] ?? []
        let first = all.first ?? [:]
        let options = (first["options"] as? [Any] ?? []).compactMap { o -> ClaudeQuestion.Option? in
            if let text = o as? String { return ClaudeQuestion.Option(label: text, detail: "") }
            guard let o = o as? [String: Any], let label = o["label"] as? String else { return nil }
            return ClaudeQuestion.Option(label: label, detail: o["description"] as? String ?? "")
        }
        return .question(ClaudeQuestion(text: first["question"] as? String ?? first["title"] as? String ?? "", options: options,
                                        multi: first["multiSelect"] as? Bool ?? false, count: all.count))
    }

    private func attach(_ reply: ClaudeReply, input: [String: Any], to i: Int) {
        let id = entries[i].notice.id
        if let old = entries[i].reply {
            // Letting go fires onGone, which would remove the entry while we hold its index.
            old.onGone = nil
            old.pass()
        }
        entries[i].reply = reply
        entries[i].input = input
        entries[i].notice.answerable = true
        reply.onGone = { [weak self] in self?.remove(id) }
        publish()
    }

    private func add(_ event: ClaudeIncoming, _ kind: ClaudeNotice.Kind, reply: ClaudeReply? = nil, input: [String: Any] = [:],
                     watch: Bool = false, hideAfter: TimeInterval? = nil) {
        // A request replaces the session's notices but not its other open requests: subagents ask in parallel.
        dismiss(session: event.session, publish: false, keepRequests: Self.isRequest(kind))
        var notice = ClaudeNotice(session: event.session, project: event.project, kind: kind, hostName: Self.hostName(event.host))
        notice.agent = event.agent
        notice.answerable = reply != nil
        var entry = Entry(notice: notice, reply: reply, host: event.host, tty: event.tty, input: input)
        let id = notice.id
        if watch, let path = Self.transcript(of: event) {
            entry.watch = TranscriptWatch(path: path, toolUseID: event.string("tool_use_id"), tool: event.string("tool_name") ?? "",
                                          input: event.json["tool_input"] as? [String: Any] ?? [:]) { [weak self] in self?.remove(id) }
        }
        reply?.onGone = { [weak self] in self?.remove(id) }
        // Unanswered requests expire, in case the session ended without telling us.
        if let delay = hideAfter ?? (watch ? Self.pendingLimit : nil) { entry.hide = scheduleHide(id, after: delay) }
        entries.append(entry)
        publish()
    }

    private func scheduleHide(_ id: UUID, after delay: TimeInterval) -> Scheduled {
        scheduler.after(delay) { [weak self] in
            guard let self else { return }
            if self.isOpen(), self.model.claude?.id == id {
                if let i = self.entries.firstIndex(where: { $0.notice.id == id }) { self.entries[i].hide = self.scheduleHide(id, after: 2) }
            } else {
                self.remove(id)
            }
        }
    }

    // MARK: - Actions from the notch

    func answer(_ id: UUID, allow: Bool) {
        guard let i = entries.firstIndex(where: { $0.notice.id == id }), let reply = entries[i].reply else { return }
        entries[i].reply = nil
        entries[i].watch?.cancel()
        reply.onGone = nil // answering closes the connection; the alert leaves after the animation
        allow ? reply.allow() : reply.deny()
        entries[i].notice.answered = (allow, scheduler.now)
        publish(animated: false)
        scheduler.after(0.55) { [weak self] in self?.remove(id) }
    }

    /// Answers AskUserQuestion: the original questions plus `answers` (multiple labels joined by commas).
    func choose(_ id: UUID, labels: [String]) {
        guard let i = entries.firstIndex(where: { $0.notice.id == id }), let reply = entries[i].reply,
              case .question(let question) = entries[i].notice.kind, !labels.isEmpty else { return }
        entries[i].reply = nil
        entries[i].watch?.cancel()
        reply.onGone = nil
        if entries[i].notice.agent == .codex {
            reply.answerCodex(question: question.text, labels: labels)
        } else {
            var updated = entries[i].input
            updated["answers"] = [question.text: labels.joined(separator: ", ")]
            reply.allow(updatedInput: updated)
        }
        entries[i].notice.answered = (true, scheduler.now)
        entries[i].notice.chosen = labels
        publish(animated: false)
        scheduler.after(0.9) { [weak self] in self?.remove(id) }
    }

    /// Brings the session's window forward. Informational alerts count as seen.
    func focus(_ id: UUID) {
        guard let entry = entries.first(where: { $0.notice.id == id }) else { Self.trace("focus: alert not found"); return }
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        Self.trace("focus: \(entry.notice.kind) host=\(entry.host?.localizedName ?? "none") tty=\(entry.tty ?? "-") pid=\(entry.host?.processIdentifier ?? 0) terminated=\(entry.host?.isTerminated ?? true) front=\(before)")
        if let host = entry.host { Self.bringForward(host, project: entry.notice.project, tty: entry.tty) }
        if entry.notice.agent == .codex {
            // Codex shows its approval prompt or question only once the hook lets go.
            switch entry.notice.kind {
            case .permission, .question: remove(id); return
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Self.trace("focus: then front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        }
        switch entry.notice.kind {
        case .done, .error, .waiting: remove(id)
        default: break
        }
    }

    /// Debug log at ~/Library/Logs/brim-claude.log, only with debugTools on.
    static func trace(_ message: String) {
        guard DebugTools.enabled else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/brim-claude.log").path
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    // MARK: - List

    private func dismiss(session: String, publish: Bool = true, keepRequests: Bool = false) {
        let ids = entries.filter { $0.notice.session == session && !(keepRequests && Self.isRequest($0.notice.kind)) }.map(\.notice.id)
        ids.forEach { remove($0, publish: false) }
        if publish, !ids.isEmpty { self.publish() }
    }

    private func remove(_ id: UUID, publish: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.notice.id == id }) else { return }
        let entry = entries.remove(at: i)
        entry.watch?.cancel()
        entry.hide?.cancel()
        entry.reply?.pass()
        if publish { self.publish() }
    }

    private func publish(animated: Bool = true) {
        // Highest priority wins; ties go to the newest.
        let top = entries.enumerated().max { a, b in
            (a.element.notice.priority, a.offset) < (b.element.notice.priority, b.offset)
        }?.element.notice
        guard top != model.claude || top?.answered?.allow != model.claude?.answered?.allow else { return }
        let appearing = model.claude == nil || model.claude?.id != top?.id
        if animated {
            withAnimation(top == nil ? .smooth : appearing ? .snappy : .smooth) { model.claude = top }
        } else {
            model.claude = top
        }
        onChange?()
    }

    // MARK: - Text

    static func describe(tool: String, input: [String: Any]) -> (String, String, Bool) {
        let file = { ((input["file_path"] as? String ?? input["notebook_path"] as? String ?? "") as NSString).lastPathComponent }
        switch tool {
        case "Bash", "PowerShell":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return (String(format: Strings.claudePermissionFor, tool), command, true)
        case "Edit", "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? [input]
            let removed = edits.reduce(0) { $0 + lines($1["old_string"] as? String) }
            let added = edits.reduce(0) { $0 + lines($1["new_string"] as? String) }
            return (String(format: Strings.claudeEdit, file()), String(format: Strings.claudeLines, added, removed), false)
        case "Write":
            return (String(format: Strings.claudeCreate, file()), String(format: Strings.claudeNewLines, lines(input["content"] as? String)), false)
        case "NotebookEdit":
            return (String(format: Strings.claudeEdit, file()), "Notebook", false)
        case "WebFetch":
            let url = input["url"] as? String ?? ""
            return (String(format: Strings.claudeOpen, URL(string: url)?.host ?? url), url, true)
        case "WebSearch":
            return (Strings.claudeSearch, input["query"] as? String ?? "", false)
        default:
            // MCP tools: mcp__server__tool
            let parts = tool.components(separatedBy: "__")
            let name = (parts.count >= 3 ? parts[2...].joined(separator: "__") : tool).replacingOccurrences(of: "_", with: " ")
            let detail = input["description"] as? String ?? (parts.count >= 3 ? parts[1] : Self.firstText(in: input))
            return (String(format: Strings.claudePermissionFor, name), detail, false)
        }
    }

    static func describeCodex(tool: String, input: [String: Any]) -> (String, String, Bool) {
        let command = input["command"] as? String ?? (input["command"] as? [String])?.joined(separator: " ") ?? ""
        switch tool {
        case "Bash":
            let line = command.split(separator: "\n").first.map(String.init) ?? ""
            return (String(format: Strings.claudePermissionFor, "Bash"), line, true)
        case "apply_patch", "Edit", "Write":
            // *** Add File: path / *** Update File: path / *** Delete File: path, then +/- lines.
            let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
            var files: [(String, Bool)] = []
            var added = 0, removed = 0
            for line in lines {
                for (prefix, isNew) in [("*** Add File: ", true), ("*** Update File: ", false), ("*** Delete File: ", false)] where line.hasPrefix(prefix) {
                    files.append(((String(line.dropFirst(prefix.count)) as NSString).lastPathComponent, isNew))
                }
                // Codex patches mark files with "*** ", never "---"/"+++": a line like "--- note" is a removed "-- note".
                if line.hasPrefix("+") { added += 1 }
                if line.hasPrefix("-") { removed += 1 }
            }
            let title = files.count > 1 ? String(format: Strings.codexEditFiles, files.count)
                : files.first.map { String(format: $0.1 ? Strings.claudeCreate : Strings.claudeEdit, $0.0) } ?? String(format: Strings.claudeEdit, "files")
            let detail = files.count == 1 && files[0].1 ? String(format: Strings.claudeNewLines, added) : String(format: Strings.claudeLines, added, removed)
            return (title, detail, false)
        default:
            if let description = input["description"] as? String, !description.isEmpty {
                return (String(format: Strings.claudePermissionFor, tool.components(separatedBy: "__").last ?? tool), description, false)
            }
            return describe(tool: tool, input: input)
        }
    }

    /// The first text value by key name, so the same request always shows the same detail.
    static func firstText(in input: [String: Any]) -> String {
        input.keys.sorted().lazy.compactMap { input[$0] as? String }.first ?? ""
    }

    static func bringForward(_ app: NSRunningApplication, project: String, tty: String? = nil) {
        // Activate like a Dock click, which switches to the window's Space. From a background app,
        // NSRunningApplication.activate() sometimes only changes the menu bar.
        let dock = { (window: CGWindowID?) in
            if let window { makeMain(window, of: app) }
            guard let url = app.bundleURL else { app.activate(); if window == nil { raiseWindow(of: app, project: project) }; return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                if window == nil { DispatchQueue.main.async { raiseWindow(of: app, project: project) } }
            }
        }
        // iTerm and Terminal: select the tab without moving windows, make its window the app's main
        // window while still in the back, then activate. Raising first made other windows flash.
        if let tty, let script = selectSessionScript(app: app, tty: tty) {
            runSelect(script) { window in dock(window) }
        } else {
            dock(nil)
        }
    }

    /// Selects the tab and pane with that tty without moving windows. Returns the window number
    /// (same as WindowServer's), or 0.
    private static func selectSessionScript(app: NSRunningApplication, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell t to select
                                tell s to select
                                return id of w
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return 0
            """
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            return id of w
                        end if
                    end repeat
                end repeat
            end tell
            return 0
            """
        default:
            return nil
        }
    }

    /// Off the main thread: the first run shows the Automation prompt, and the target app may be busy.
    private static func runSelect(_ source: String, done: @escaping @MainActor (CGWindowID?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let number = result.map { $0.int32Value } ?? 0
            let window: CGWindowID? = number > 0 ? CGWindowID(number) : nil
            let detail = error.map { "error \($0[NSAppleScript.errorNumber] ?? "?")" } ?? (window.map { "window \($0)" } ?? "not found")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    trace("tab by tty: \(detail)")
                    done(window)
                }
            }
        }
    }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    // Private but stable for years: the WindowServer number of an AX window.
    private static let axGetWindow: GetWindowFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindowFn.self) }

    /// Makes the window its app's main window without raising it.
    private static func makeMain(_ number: CGWindowID, of app: NSRunningApplication) {
        guard AXIsProcessTrusted(), let axGetWindow else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var id: CGWindowID = 0
            if axGetWindow(window, &id) == .success, id == number {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    /// Picks the window whose title has the project name (VS Code shows the folder there).
    private static func raiseWindow(of app: NSRunningApplication, project: String) {
        guard project != "~", AXIsProcessTrusted() else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let wanted = project.lowercased()
        let match = windows.first { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = (title as? String)?.lowercased() else { return false }
            // Whole words, so "brim" doesn't match "brimstone".
            let words = text.components(separatedBy: CharacterSet(charactersIn: " —–-·|:/\\()[]•"))
            return words.contains(wanted) || text.contains(" \(wanted) ") || text.hasPrefix(wanted + " ")
        }
        guard let match else { return }
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func hostName(_ app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        switch app.bundleIdentifier {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.openai.codex": return "Codex"
        default: return app.localizedName
        }
    }

    static func lines(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Last paragraph of the reply as plain text. It is usually the conclusion or a question.
    static func summary(of message: String) -> String {
        // Code goes first, before splitting: a fence may hold blank lines. An unclosed one runs to the end.
        let prose = message.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: "\n\n", options: .regularExpression)
        var paragraphs = prose.components(separatedBy: "\n\n").map {
            $0.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
              .replacingOccurrences(of: #"(?m)^\s*(#+|[-*]|\d+\.)\s+"#, with: "", options: .regularExpression)
              .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
              .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
              .trimmingCharacters(in: .whitespaces)
        }
        paragraphs.removeAll { $0.isEmpty }
        return paragraphs.last ?? ""
    }
}
