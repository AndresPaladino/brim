import Testing
import Foundation
@testable import Brim

/// Cost of handling Claude events on the main thread. Each event is handled while the user may be
/// scrolling or animating, so it should stay well under a frame (8 ms at 120 Hz).
@MainActor
@Suite struct ClaudeCostTests {
    func measure(_ n: Int, _ body: (Int) -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n { body(i) }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
    }

    @Test func costPerEvent() {
        let message = "Done.\n\n```swift\nlet x = 1\n```\n\nI updated the [docs](https://x.y) and ran **all** tests: 48 pass."
        let summary = measure(2000) { _ in _ = ClaudeCenter.summary(of: message) }
        let describe = measure(2000) { _ in _ = ClaudeCenter.describe(tool: "Edit", input: ["file_path": "/a/b.swift", "old_string": "a\nb", "new_string": "c"]) }
        let h = ClaudeHarness()
        let stop = measure(500) { i in h.send("Stop", session: "s\(i)", ["last_assistant_message": message]) }
        let h2 = ClaudeHarness()
        let prompt = measure(500) { i in h2.send("UserPromptSubmit", session: "s\(i)") }
        let h3 = ClaudeHarness()
        for i in 0..<500 { h3.send("UserPromptSubmit", session: "s\(i)") }
        let stopAfterMany = measure(200) { i in h3.send("Stop", session: "x\(i)", ["last_assistant_message": message]) }
        let line = String(format: "ms per call: summary %.3f, describe %.3f, Stop %.3f, UserPromptSubmit %.3f, Stop with 500 sessions known %.3f",
                          summary, describe, stop, prompt, stopAfterMany)
        print(line)
        PerfLog.record("claude.summary_ms", summary)
        PerfLog.record("claude.stop_event_ms", stop)
        PerfLog.record("claude.prompt_event_ms", prompt)
        #expect(stop < 2, "\(line)")
        #expect(prompt < 2, "\(line)")
    }
}

/// Appends metrics to $BRIM_REPORT/metrics.tsv when the test script sets it.
enum PerfLog {
    static func record(_ name: String, _ value: Double) {
        guard let dir = ProcessInfo.processInfo.environment["REPORT"] else { return }
        let line = "\(name)\t\(String(format: "%.4f", value))\n"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("metrics.tsv")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
