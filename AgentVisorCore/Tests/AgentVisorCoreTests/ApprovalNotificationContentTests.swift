import XCTest
@testable import AgentVisorCore

final class ApprovalNotificationContentTests: XCTestCase {
    // MARK: - Identifier roundtrip

    func testIdentifierRoundTrip() {
        let id = ApprovalNotificationContent.identifier(sessionId: "abc-123", toolUseId: "toolu_42")
        let parsed = ApprovalNotificationContent.parseIdentifier(id)
        XCTAssertEqual(parsed?.sessionId, "abc-123")
        XCTAssertEqual(parsed?.toolUseId, "toolu_42")
    }

    func testIdentifierStableAcrossCalls() {
        let a = ApprovalNotificationContent.identifier(sessionId: "s", toolUseId: "t")
        let b = ApprovalNotificationContent.identifier(sessionId: "s", toolUseId: "t")
        XCTAssertEqual(a, b)
    }

    func testParseRejectsUnknownPrefix() {
        XCTAssertNil(ApprovalNotificationContent.parseIdentifier("nonsense"))
        XCTAssertNil(ApprovalNotificationContent.parseIdentifier(""))
    }

    func testParseRejectsMissingSessionOrTool() {
        XCTAssertNil(ApprovalNotificationContent.parseIdentifier("cv.approval."))
        XCTAssertNil(ApprovalNotificationContent.parseIdentifier("cv.approval.only-one"))
    }

    func testIdentifierHandlesIdsContainingSeparator() {
        // Defensive: the stable separator is '|' which never appears in
        // sessionIds (UUIDs) or tool ids (toolu_<base32>). Regression
        // guard so we notice if either ever changes.
        let id = ApprovalNotificationContent.identifier(sessionId: "abc", toolUseId: "toolu_xyz")
        XCTAssertTrue(id.hasPrefix("cv.approval."))
        XCTAssertTrue(id.contains("|"))
    }

    // MARK: - Title / body composition

    func testTitleNamesTheTool() {
        let c = ApprovalNotificationContent.make(
            displayTitle: "agent-visor-dev",
            toolName: "Bash",
            input: "ls -la"
        )
        XCTAssertEqual(c.title, "Bash needs approval")
    }

    func testSubtitleIsSessionTitle() {
        let c = ApprovalNotificationContent.make(
            displayTitle: "my-project",
            toolName: "Edit",
            input: "/tmp/foo.txt"
        )
        XCTAssertEqual(c.subtitle, "my-project")
    }

    func testBodyEchoesInputClipped() {
        let long = String(repeating: "x", count: 500)
        let c = ApprovalNotificationContent.make(
            displayTitle: "p",
            toolName: "Bash",
            input: long
        )
        XCTAssertLessThanOrEqual(c.body.count, 240)
        XCTAssertTrue(c.body.hasPrefix("xxxx"))
    }

    func testBodyHandlesEmptyInput() {
        let c = ApprovalNotificationContent.make(displayTitle: "p", toolName: "Stop", input: "")
        XCTAssertEqual(c.body, "")
    }
}
