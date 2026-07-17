import XCTest
@testable import AgentVisorCore

final class SidebarSessionVisibilityPolicyTests: XCTestCase {
    func testEndedConversationSessionHidesFromActiveSidebar() {
        XCTAssertTrue(SidebarSessionVisibilityPolicy.shouldHideInWindow(
            isEnded: true,
            isTitleless: false
        ))
    }

    func testLiveConversationSessionStaysVisible() {
        XCTAssertFalse(SidebarSessionVisibilityPolicy.shouldHideInWindow(
            isEnded: false,
            isTitleless: false
        ))
    }

    func testLiveTitlelessSessionHides() {
        XCTAssertTrue(SidebarSessionVisibilityPolicy.shouldHideInWindow(
            isEnded: false,
            isTitleless: true
        ))
    }

    func testIdleSessionStaysVisibleInWindow() {
        XCTAssertFalse(SidebarSessionVisibilityPolicy.shouldHideInWindow(
            isEnded: false,
            isTitleless: false
        ))
    }

    func testIdleSessionHidesFromPills() {
        XCTAssertTrue(SidebarSessionVisibilityPolicy.shouldHideInPills(
            isEnded: false,
            isTitleless: false,
            isIdle: true
        ))
    }

    func testNonIdleActiveOrReadySessionStaysVisibleInPills() {
        XCTAssertFalse(SidebarSessionVisibilityPolicy.shouldHideInPills(
            isEnded: false,
            isTitleless: false,
            isIdle: false
        ))
    }
}
