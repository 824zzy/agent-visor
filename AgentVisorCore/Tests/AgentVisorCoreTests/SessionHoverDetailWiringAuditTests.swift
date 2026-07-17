import XCTest

final class SessionHoverDetailWiringAuditTests: XCTestCase {
    func testPillHoverCardUsesSourceAwareLatestTurnPresentation() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Components/SessionDetailPopover.swift"))

        XCTAssertTrue(source.contains("SessionHoverDetailPolicy.presentation("))
        XCTAssertTrue(source.contains("SessionHoverDetailPolicy.sourceDisplayName("))
        XCTAssertTrue(source.contains("effortLevel: session.effortLevel"))
        XCTAssertTrue(source.contains("codexApprovalPolicy: session.conversationInfo.lastCodexApprovalPolicy"))
        XCTAssertTrue(source.contains("codexSandboxPolicyType: session.conversationInfo.lastCodexSandboxPolicyType"))
        XCTAssertTrue(source.contains(".frame(width: 300"))
    }

    func testPillHoverCardShowsTheConfiguredShortcutForItsRenderedSlot() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let popover = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/SessionDetailPopover.swift"))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift"))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Events/GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(popover.contains("shortcutModifierFamily: shortcutModifierFamily"))
        XCTAssertTrue(popover.contains("shortcutPosition: shortcutPosition"))
        XCTAssertTrue(popover.contains("presentation.shortcutLabel"))
        XCTAssertTrue(popover.contains("Text(\"Open directly\")"))
        XCTAssertTrue(sideContent.contains("shortcutPosition: pill.shortcutPosition"))
        XCTAssertTrue(sideContent.contains("shortcutModifierFamily: sessionShortcutManager.family"))
        XCTAssertTrue(manager.contains("@Published private(set) var family"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
