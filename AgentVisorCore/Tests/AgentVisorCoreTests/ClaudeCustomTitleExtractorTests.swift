import XCTest
@testable import AgentVisorCore

/// Pins the rule for surfacing Zed's user-set thread title from a
/// Claude JSONL transcript.
///
/// Background: Zed's `claude-acp` adapter wraps the Claude CLI and writes
/// metadata rows of shape `{"type":"custom-title","customTitle":"misc2",
/// "sessionId":"..."}` into the same `~/.claude/projects/.../<id>.jsonl`
/// file the CLI normally writes. Those rows aren't part of the regular
/// CLI's transcript schema; agent-visor's parser ignored them, so
/// Zed-hosted Claude sessions showed up in the sidebar with their UUID
/// prefix instead of the user-set title.
///
/// Rule: scan JSONL lines, take the **last** `custom-title` row whose
/// `customTitle` is a non-empty string, and return its value. "Last
/// wins" so a user who renames the thread sees the new name; the
/// transcript carries every previous title too.
final class ClaudeCustomTitleExtractorTests: XCTestCase {

    func testReturnsNilWhenNoCustomTitleLine() {
        let jsonl = """
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","message":{"content":"hello"}}
        """
        XCTAssertNil(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl))
    }

    func testReturnsCustomTitle() {
        let jsonl = """
        {"type":"custom-title","customTitle":"misc2","sessionId":"abc"}
        {"type":"user","message":{"content":"hi"}}
        """
        XCTAssertEqual(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl), "misc2")
    }

    func testLastWinsWhenMultipleTitlesPresent() {
        // The user renamed the thread mid-conversation — Zed appended a
        // new custom-title row. The most recent one is what's visible
        // in Zed's sidebar; agent-visor must mirror that.
        let jsonl = """
        {"type":"custom-title","customTitle":"draft 1","sessionId":"abc"}
        {"type":"user","message":{"content":"hi"}}
        {"type":"custom-title","customTitle":"draft 2","sessionId":"abc"}
        {"type":"assistant","message":{"content":"hello"}}
        {"type":"custom-title","customTitle":"final","sessionId":"abc"}
        """
        XCTAssertEqual(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl), "final")
    }

    func testEmptyTitleIsIgnored() {
        // Don't return "" — the row exists but has no useful data; let
        // the caller fall through to firstUserMessage / id prefix.
        let jsonl = """
        {"type":"custom-title","customTitle":"","sessionId":"abc"}
        """
        XCTAssertNil(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl))
    }

    func testWhitespaceOnlyTitleIsIgnored() {
        let jsonl = """
        {"type":"custom-title","customTitle":"   ","sessionId":"abc"}
        """
        XCTAssertNil(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl))
    }

    func testTrimsWhitespaceAroundTitle() {
        let jsonl = """
        {"type":"custom-title","customTitle":"  bug fixes  ","sessionId":"abc"}
        """
        XCTAssertEqual(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl), "bug fixes")
    }

    func testIgnoresRowsThatLackCustomTitleField() {
        // Defensive: a malformed `custom-title` row (no `customTitle`
        // field) shouldn't crash the parser; just skip it and fall
        // through to whatever earlier rows have.
        let jsonl = """
        {"type":"custom-title","sessionId":"abc"}
        {"type":"custom-title","customTitle":"good","sessionId":"abc"}
        """
        XCTAssertEqual(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl), "good")
    }

    func testIgnoresOtherRowTypes() {
        let jsonl = """
        {"type":"user","customTitle":"should not match"}
        {"type":"assistant","customTitle":"also should not match"}
        """
        XCTAssertNil(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl))
    }

    func testHandlesMalformedJSONLines() {
        let jsonl = """
        not even json
        {"type":"custom-title","customTitle":"valid","sessionId":"abc"}
        also not json
        """
        XCTAssertEqual(ClaudeCustomTitleExtractor.extractTitle(jsonl: jsonl), "valid")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ClaudeCustomTitleExtractor.extractTitle(jsonl: ""))
    }
}
