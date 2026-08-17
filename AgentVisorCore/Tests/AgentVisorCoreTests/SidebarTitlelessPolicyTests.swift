import XCTest
@testable import AgentVisorCore

/// Covers the sidebar title rule through whole sessions.
///
/// The rule used to take nine loose fields, and these tests named all nine every time. They now
/// build a session and set only the field under test, so a reader can see what each case is for.
final class SidebarTitlelessPolicyTests: XCTestCase {
    func testTitlelessTerminalSessionWithTTYStaysVisible() {
        let session = SessionStateFixture.make(tty: "ttys003", terminalHost: .iterm2)
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testTitlelessNoTTYClaudeSessionHides() {
        let session = SessionStateFixture.make(terminalHost: .unknown)
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testTitlelessZedWithoutConversationHides() {
        let session = SessionStateFixture.make(terminalHost: .zed)
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testTitlelessZedWithConversationStaysVisible() {
        let session = SessionStateFixture.make(
            terminalHost: .zed,
            lastActivityDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testObservedCodexTitlelessSessionHides() {
        let session = SessionStateFixture.make(agentID: .codex)
        XCTAssertTrue(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testSelectedTitlelessSessionStaysVisible() {
        let session = SessionStateFixture.make(terminalHost: .zed)
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: true,
            needsAttention: false
        ))
    }

    // MARK: - Cases the field-based tests could not reach

    func testAttentionKeepsTitleVisible() {
        let session = SessionStateFixture.make(terminalHost: .unknown)
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: true
        ))
    }

    func testCursorRowWithoutTTYStaysVisible() {
        let session = SessionStateFixture.make(agentID: .cursor)
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testSessionNameKeepsTitleVisible() {
        let session = SessionStateFixture.make(sessionName: "release triage")
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testWhitespaceSessionNameStillCountsAsAName() {
        let session = SessionStateFixture.make(sessionName: "   ")
        XCTAssertFalse(
            SidebarTitlelessPolicy.shouldHide(
                session: session,
                isSelected: false,
                needsAttention: false
            ),
            """
            Today the rule tests `isEmpty`, so a name of spaces keeps the title. \
            This test pins that behaviour. Trimming the name would change what the sidebar \
            shows, so it belongs in its own change, not in this move to session arguments.
            """
        )
    }

    func testFirstUserMessageKeepsTitleVisible() {
        let session = SessionStateFixture.make(firstUserMessage: "fix the pill strip")
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }

    func testChatItemsKeepTitleVisible() {
        let session = SessionStateFixture.make(chatItems: [
            ChatHistoryItem(id: "item-1", type: .user("hello"), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        XCTAssertFalse(SidebarTitlelessPolicy.shouldHide(
            session: session,
            isSelected: false,
            needsAttention: false
        ))
    }
}
