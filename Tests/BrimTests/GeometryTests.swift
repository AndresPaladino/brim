import Testing
import Foundation
@testable import Brim

/// Island sizes against the measurements validated in the prototypes (HANDOFF: HUD 288 wide, player 396, ...).
@MainActor
@Suite struct GeometryTests {
    let notch = IslandGeometry(notch: CGSize(width: 188, height: 33.5), hasNotch: true)
    let flat = IslandGeometry(notch: CGSize(width: 0, height: 24), hasNotch: false)

    @Test func layoutConstants() {
        #expect(IslandLayout.hudWidth.isApprox(288))
        #expect(IslandLayout.hudContentHeight.isApprox(41.4))
        #expect(IslandLayout.hudRadius.isApprox(21.6))
        #expect(IslandLayout.mediaWidth.isApprox(396))
        #expect(IslandLayout.mediaContentHeight.isApprox(111.6))
        #expect(IslandLayout.mediaRadius.isApprox(27))
        #expect(IslandLayout.compactEarWidth.isApprox(37.8))
        #expect(IslandLayout.recordingEarWidth(claude: false) == 46)
        #expect(IslandLayout.recordingEarWidth(claude: true) == 56)
        #expect(IslandLayout.deviceWidth == 340 && IslandLayout.deviceContentHeight == 60)
        #expect(IslandLayout.chargeWidth == 300 && IslandLayout.chargeContentHeight == 54)
        #expect(IslandLayout.ear == 7)
    }

    @Test func sizesWithNotch() {
        #expect(notch.size(.idle) == CGSize(width: 188, height: 33.5))
        #expect(notch.size(.hud).width.isApprox(288) && notch.size(.hud).height.isApprox(33.5 + 41.4))
        #expect(notch.size(.media).width.isApprox(396) && notch.size(.media).height.isApprox(33.5 + 111.6))
        #expect(notch.size(.compact).width.isApprox(188 + 2 * 37.8))
        #expect(notch.size(.recording) == CGSize(width: 188 + 92, height: 33.5))
        #expect(notch.size(.device) == CGSize(width: 340, height: 93.5))
        #expect(notch.size(.charge) == CGSize(width: 300, height: 87.5))
        #expect(notch.size(.boop) == CGSize(width: 214, height: 79.5))
    }

    @Test func sizesWithoutNotch() {
        #expect(flat.size(.idle) == CGSize(width: 110, height: 0))
        #expect(flat.size(.compact) == CGSize(width: 128, height: 24))
        #expect(flat.size(.recording) == CGSize(width: 16 + 92, height: 24))
        #expect(flat.size(.boop).width == 120) // min width when the notch is 0
        #expect(flat.size(.hud).height.isApprox(24 + 41.4))
    }

    @Test(arguments: ["a", "brim", "my-project", "a-really-long-project-name-that-goes-on-and-on", "日本語のプロジェクト", "🙂🙂🙂", ""])
    func claudeEarStaysWithinBounds(project: String) {
        for kind in [ClaudeNotice.Kind.waiting, .permission(title: "t", detail: "d", code: false), .done(summary: "s", minutes: nil), .error("x")] {
            let n = ClaudeNotice(session: "s", project: project, kind: kind, hostName: nil)
            let w = ClaudeLayout.earWidth(n)
            #expect(w >= ClaudeLayout.earWidth && w <= ClaudeLayout.earMaxWidth, "\(project) \(kind): \(w)")
            #expect(notch.size(.claudeEar, claude: n).width == 188 + 2 * w)
        }
        #expect(ClaudeLayout.earWidth(nil) == 54)
    }

    @Test func tallestDropFitsTheWindowCanvas() {
        // The window canvas is 640 × max(240, tallest + 72); every Claude drop must fit inside.
        let canvasHeight = max(240, ClaudeLayout.tallest + 72)
        #expect(ClaudeLayout.tallest.isApprox(255))
        let q = ClaudeQuestion(text: String(repeating: "word ", count: 30), options: (1...4).map { .init(label: "Option \($0)", detail: "") }, multi: true, count: 1)
        var n = ClaudeNotice(session: "s", project: "p", kind: .question(q), hostName: nil)
        n.answerable = true
        let size = ClaudeLayout.size(n, notch: CGSize(width: 188, height: 33.5))
        #expect(size.height <= canvasHeight)
        #expect(size.width + 2 * IslandLayout.ear <= 640)
        for mode in [IslandMode.media, .hud, .device, .charge, .boop] {
            #expect(notch.size(mode).width + 2 * IslandLayout.ear <= 640)
            #expect(notch.size(mode).height <= canvasHeight)
        }
    }

    @Test func questionLines() {
        #expect(ClaudeLayout.questionLines("Short?") == 1)
        #expect(ClaudeLayout.questionLines(String(repeating: "word ", count: 20)) >= 2)
        #expect(ClaudeLayout.questionLines("") == 1)
        let long = ClaudeQuestion(text: String(repeating: "word ", count: 60), options: [.init(label: "a", detail: "")], multi: false, count: 1)
        #expect(!long.fitsNotch)
        let ok = ClaudeQuestion(text: "Which one?", options: [.init(label: "a", detail: ""), .init(label: "b", detail: "")], multi: false, count: 1)
        #expect(ok.fitsNotch)
        #expect(!ClaudeQuestion(text: "Which one?", options: [], multi: false, count: 1).fitsNotch)
        #expect(!ClaudeQuestion(text: "Which one?", options: (1...5).map { .init(label: "\($0)", detail: "") }, multi: false, count: 1).fitsNotch)
        #expect(!ClaudeQuestion(text: "Which one?", options: ok.options, multi: false, count: 2).fitsNotch)
        #expect(!ClaudeQuestion(text: "Which?", options: [.init(label: String(repeating: "W", count: 40), detail: "")], multi: false, count: 1).fitsNotch)
    }

    @Test func dropSizes() {
        let n = { (k: ClaudeNotice.Kind) in ClaudeNotice(session: "s", project: "p", kind: k, hostName: nil) }
        #expect(ClaudeLayout.content(n(.permission(title: "", detail: "", code: false))) == CGSize(width: 380, height: 56))
        #expect(ClaudeLayout.content(n(.done(summary: "", minutes: nil))) == CGSize(width: 430, height: 64))
        #expect(ClaudeLayout.content(n(.waiting)) == CGSize(width: 380, height: 56))
        // A question that isn't answerable shows as a link, not a list.
        let q = ClaudeQuestion(text: "Pick?", options: [.init(label: "a", detail: "")], multi: false, count: 1)
        #expect(ClaudeLayout.content(n(.question(q))) == CGSize(width: 420, height: 82))
        var answerable = n(.question(q)); answerable.answerable = true
        #expect(ClaudeLayout.content(answerable).height == ClaudeLayout.listHeight(q))
    }
}

extension CGFloat {
    func isApprox(_ other: CGFloat, _ eps: CGFloat = 0.001) -> Bool { abs(self - other) < eps }
}
