import XCTest
@testable import AgentVisorCore

final class ModeBadgeParserTests: XCTestCase {
    func testParsesAutoModeBadge() {
        let text = """
        Some prior output here
          Opus 4.7|xhigh ████ 45%
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "auto")
    }

    func testParsesPlanModeBadge() {
        let text = """
        ──────────────
          Opus 4.7|xhigh ████ 45%
          ⏸ plan mode on (shift+tab to cycle)
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "plan")
    }

    func testParsesAcceptEditsBadge() {
        let text = """
          Opus 4.7|xhigh ████ 45%
          ⏵⏵ accept edits on (shift+tab to cycle)
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "acceptEdits")
    }

    func testParsesBypassPermissionsBadge() {
        let text = """
          Opus 4.7|xhigh ████ 45%
          ⏵⏵ bypass permissions (shift+tab to cycle)
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "bypassPermissions")
    }

    func testReturnsNilWhenNoBadgePresent() {
        let text = "just some shell output\n$ ls -la\n"
        XCTAssertNil(ModeBadgeParser.parse(text))
    }

    func testReturnsMostRecentBadgeWhenMultiplePresent() {
        // Scrollback earlier mentions auto; the *current* status line is plan.
        // Parser must return the latter, not the former.
        let text = """
        old scrollback line: ⏵⏵ auto mode on (shift+tab to cycle)
        ... lots of intervening output ...
        current status line:
          Opus 4.7|xhigh ████ 45%
          ⏸ plan mode on (shift+tab to cycle)
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "plan")
    }

    func testInfersDefaultWhenTUIActiveButNoBadge() {
        // Claude Code in default mode renders the input box (box-drawing
        // chars) but no chevron-prefixed badge. Parser should call this
        // "default", not nil — nil is reserved for "we don't know".
        let text = """
        ╭───────────────────────────────────────╮
        │ > How can I help today?               │
        ╰───────────────────────────────────────╯
          Opus 4.7|xhigh ████ 45%
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "default")
    }

    func testInfersDefaultForRedesignedPromptWithoutBox() {
        // Post-redesign Claude Code drops the full box around the
        // input row; only a horizontal rule + `❯` chevron remain.
        // Parser must still infer default mode here, otherwise the
        // chip falls back to whatever was last shown (e.g. acceptEdits
        // from a prior probe tick) and the wrong mode persists.
        let text = """
        ── agent-visor-dev ──
        ❯
        ───────────────────────────────────────────────────
          Opus 4.7|xhigh | Bedrock █░░░░░░░░░ 14% | AgentVisorCore
          ← for agents
        """
        XCTAssertEqual(ModeBadgeParser.parse(text), "default")
    }

    func testIgnoresBadgeBuriedInOldScrollback() {
        // A badge near the start of a long buffer must not beat a default-
        // mode TUI rendered at the tail. Otherwise the chip stays stuck on
        // a stale mode after the user cycles back to default.
        let staleBadge = "old session start: ⏵⏵ auto mode on (shift+tab to cycle)\n"
        let padding = String(repeating: "intervening output line\n", count: 100)
        let currentTui = """
        ╭───────────────────────────────────────╮
        │ > waiting for input                   │
        ╰───────────────────────────────────────╯
          Opus 4.7|xhigh ████ 45%
        """
        let text = staleBadge + padding + currentTui
        XCTAssertEqual(ModeBadgeParser.parse(text), "default")
    }
}
