import XCTest
@testable import AgentVisorCore

final class SessionDeletabilityTests: XCTestCase {
    // Claude Code: the only agent whose transcript Agent Visor can delete —
    // and only when the session is NOT live (deleting a live one leaves
    // `claude` writing to an unlinked fd).
    func testClaudeCodeNotLiveIsDeletable() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .claudeCode, isLive: false),
            .deletableTranscript
        )
    }

    func testClaudeCodeLiveIsHideOnly() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .claudeCode, isLive: true),
            .hideOnly
        )
    }

    // Codex: state_5.sqlite is read-only by design and the rollout is owned by
    // Codex's engine — never deletable regardless of liveness.
    func testCodexIsHideOnlyWhenLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .codex, isLive: true),
            .hideOnly
        )
    }

    func testCodexIsHideOnlyWhenNotLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .codex, isLive: false),
            .hideOnly
        )
    }

    // Cursor: observed, read-only.
    func testCursorIsHideOnlyWhenLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .cursor, isLive: true),
            .hideOnly
        )
    }

    func testCursorIsHideOnlyWhenNotLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .cursor, isLive: false),
            .hideOnly
        )
    }

    // Auggie/Zed: observed, read-only.
    func testAuggieIsHideOnlyWhenLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .auggie, isLive: true),
            .hideOnly
        )
    }

    func testAuggieIsHideOnlyWhenNotLive() {
        XCTAssertEqual(
            SessionDeletabilityPolicy.deletability(agentID: .auggie, isLive: false),
            .hideOnly
        )
    }
}
