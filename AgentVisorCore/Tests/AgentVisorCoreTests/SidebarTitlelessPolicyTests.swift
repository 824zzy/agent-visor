import XCTest
@testable import AgentVisorCore

final class SidebarTitlelessPolicyTests: XCTestCase {
    func testTitlelessTerminalSessionWithTTYStaysVisible() {
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: false,
            agentID: .claudeCode,
            terminalHost: .iterm2,
            hasTTY: true,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: false
        ))
    }

    func testTitlelessNoTTYClaudeSessionHides() {
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: false,
            agentID: .claudeCode,
            terminalHost: .unknown,
            hasTTY: false,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: false
        ))
    }

    func testTitlelessZedWithoutConversationHides() {
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: false,
            agentID: .claudeCode,
            terminalHost: .zed,
            hasTTY: false,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: false
        ))
    }

    func testTitlelessZedWithConversationStaysVisible() {
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: false,
            agentID: .claudeCode,
            terminalHost: .zed,
            hasTTY: false,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: true
        ))
    }

    func testObservedCodexTitlelessSessionHides() {
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: false,
            agentID: .codex,
            terminalHost: nil,
            hasTTY: false,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: false
        ))
    }

    func testSelectedTitlelessSessionStaysVisible() {
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            isSelected: true,
            needsAttention: false,
            agentID: .claudeCode,
            terminalHost: .zed,
            hasTTY: false,
            hasSessionName: false,
            hasFirstUserMessage: false,
            hasChatItems: false,
            hasLastActivityDate: false
        ))
    }
}
