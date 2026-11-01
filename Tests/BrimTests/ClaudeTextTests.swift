import Testing
import Foundation
@testable import Brim

/// What the notch says about each tool call and reply. Strings come from the English bundle.
@MainActor
@Suite(.serialized) struct ClaudeTextTests {
    init() { Strings.bundle = Bundle(url: Repo.resources.appendingPathComponent("en.lproj"))! }

    @Test func bashShowsTheFirstLine() {
        let d = ClaudeCenter.describe(tool: "Bash", input: ["command": "cd x\nnpm test"])
        #expect(d.1 == "cd x" && d.2)
        #expect(d.0.contains("Bash"))
        #expect(ClaudeCenter.describe(tool: "Bash", input: [:]).1 == "")
    }

    @Test func editCountsLines() {
        let d = ClaudeCenter.describe(tool: "Edit", input: ["file_path": "/a/b/View.swift", "old_string": "a\nb", "new_string": "a\nb\nc"])
        #expect(d.0.contains("View.swift") && !d.2)
        #expect(d.1.contains("3") && d.1.contains("2"))
        let multi = ClaudeCenter.describe(tool: "MultiEdit", input: ["file_path": "/x.swift", "edits": [["old_string": "a", "new_string": "b\nc"], ["old_string": "d\ne", "new_string": ""]]])
        #expect(multi.1.contains("2") && multi.1.contains("3")) // +2 −3
    }

    @Test func writeAndNotebookAndWeb() {
        #expect(ClaudeCenter.describe(tool: "Write", input: ["file_path": "/x/New.swift", "content": "1\n2\n3\n"]).0.contains("New.swift"))
        #expect(ClaudeCenter.describe(tool: "NotebookEdit", input: ["notebook_path": "/x/a.ipynb"]).1 == "Notebook")
        let web = ClaudeCenter.describe(tool: "WebFetch", input: ["url": "https://developer.apple.com/documentation"])
        #expect(web.0.contains("developer.apple.com") && web.2)
        #expect(ClaudeCenter.describe(tool: "WebFetch", input: ["url": "not a url"]).0.contains("not a url"))
        #expect(ClaudeCenter.describe(tool: "WebSearch", input: ["query": "swift testing"]).1 == "swift testing")
    }

    @Test func mcpToolNames() {
        let d = ClaudeCenter.describe(tool: "mcp__claude_ai_Google_Calendar__create_event", input: ["description": "Create event"])
        #expect(d.0.contains("create event") && d.1 == "Create event")
        let noDescription = ClaudeCenter.describe(tool: "mcp__github__create_issue", input: ["title": "x"])
        #expect(noDescription.1 == "github")
    }

    /// Non-MCP unknown tools used to fall back to "the first string value" of a dictionary, whose order
    /// is random per process. Now it's the first by key name.
    @Test func unknownToolDetailIsDeterministic() {
        let input: [String: Any] = ["alpha": "first value", "beta": "second value", "gamma": "third value", "delta": "fourth"]
        let shown = Set((0..<50).map { _ in ClaudeCenter.describe(tool: "SomeTool", input: Dictionary(uniqueKeysWithValues: input.map { ($0.key, $0.value) })).1 })
        #expect(shown == ["first value"], "picked \(shown)")
        #expect(ClaudeCenter.firstText(in: ["a": 1, "b": ["x"], "c": "text"]) == "text")
        #expect(ClaudeCenter.firstText(in: [:]) == "")
    }

    @Test func codexPatchSummaries() {
        let patch = "*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-a\n+b\n+c\n*** Add File: Sources/B.swift\n+x\n*** End Patch"
        let d = ClaudeCenter.describeCodex(tool: "apply_patch", input: ["command": patch])
        #expect(d.0.contains("2"))
        #expect(d.1.contains("3") && d.1.contains("1")) // +3 −1
        let one = ClaudeCenter.describeCodex(tool: "apply_patch", input: ["command": "*** Add File: New.swift\n+1\n+2"])
        #expect(one.0.contains("New.swift") && one.1.contains("2"))
        #expect(ClaudeCenter.describeCodex(tool: "Bash", input: ["command": ["git", "push"]]).1 == "git push")
        #expect(ClaudeCenter.describeCodex(tool: "mcp__x__do_thing", input: ["description": "Does it"]).0.contains("do_thing"))
    }

    /// A removed line that starts with "--" (SQL comment, CLI flag) is "---..." in the patch and used
    /// not to be counted as a diff header.
    @Test func patchRemovedLineStartingWithDashes() {
        let patch = "*** Update File: q.sql\n@@\n--- old comment\n+-- new comment"
        let d = ClaudeCenter.describeCodex(tool: "apply_patch", input: ["command": patch])
        #expect(d.1 == String(format: Strings.claudeLines, 1, 1), "got \(d.1)")
        let plus = ClaudeCenter.describeCodex(tool: "apply_patch", input: ["command": "*** Update File: a.c\n@@\n+++i;\n-i++;"])
        #expect(plus.1 == String(format: Strings.claudeLines, 1, 1), "got \(plus.1)")
    }

    @Test func summaryTakesTheLastParagraph() {
        #expect(ClaudeCenter.summary(of: "First.\n\nSecond, the conclusion.") == "Second, the conclusion.")
        #expect(ClaudeCenter.summary(of: "Use [the docs](https://x.y) and **bold** `code`.") == "Use the docs and bold code.")
        #expect(ClaudeCenter.summary(of: "## Title\n\n- one\n- two") == "one two")
        #expect(ClaudeCenter.summary(of: "") == "")
        #expect(ClaudeCenter.summary(of: "\n\n\n\n") == "")
        #expect(ClaudeCenter.summary(of: "Done.\n\n```swift\nlet x = 1\n```") == "Done.")
    }

    /// Fenced code with a blank line inside used to be split into paragraphs before the fence was
    /// removed, so half the code ended up as the summary.
    @Test func summaryNeverShowsCode() {
        let message = "Here is the fix.\n\n```swift\nfunc a() {\n    b()\n\n    c()\n}\n```"
        #expect(ClaudeCenter.summary(of: message) == "Here is the fix.")
        #expect(ClaudeCenter.summary(of: "Done.\n\n```\nlet x = 1\n\nlet y = 2") == "Done.", "unclosed fence")
        #expect(ClaudeCenter.summary(of: "First.\n```\ncode\n```\nThen this.") == "Then this.")
    }

    @Test func questionParsing() {
        let k = ClaudeCenter.question(["questions": [["question": "Q?", "multiSelect": true, "options": [["label": "A", "description": "a"], ["label": "B"], ["nolabel": 1], "C"]]]])
        guard case .question(let q) = k else { Issue.record("not a question"); return }
        #expect(q.text == "Q?" && q.multi && q.count == 1)
        #expect(q.options.map(\.label) == ["A", "B", "C"])
        guard case .question(let empty) = ClaudeCenter.question([:]) else { return }
        #expect(empty.text == "" && empty.options.isEmpty && empty.count == 0)
    }

    @Test func projectName() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let e = { (cwd: String) in ClaudeIncoming(agent: .claude, name: "x", session: "s", cwd: cwd, json: [:], host: nil, tty: nil).project }
        #expect(e("/Users/x/Projects/brim") == "brim")
        #expect(e("") == "~")
        #expect(e(home) == "~")
        #expect(e(home + "/") == "~")
        #expect(e("/") == "/")
    }

    @Test func linesCount() {
        #expect(ClaudeCenter.lines(nil) == 0)
        #expect(ClaudeCenter.lines("") == 0)
        #expect(ClaudeCenter.lines("a") == 1)
        #expect(ClaudeCenter.lines("a\nb\n") == 3) // trailing newline counts as a line
    }
}
