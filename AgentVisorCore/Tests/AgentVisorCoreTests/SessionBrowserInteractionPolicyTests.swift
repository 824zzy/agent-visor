import XCTest
@testable import AgentVisorCore

final class SessionBrowserInteractionPolicyTests: XCTestCase {
    func testKeyboardMoveAdvancesCursorAndRequestsReveal() {
        let decision = SessionBrowserInteractionPolicy.reduce(
            currentCursorID: "one",
            visibleSessionIDs: ["one", "two", "three"],
            event: .keyboardMove(offset: 1)
        )

        XCTAssertEqual(decision.cursorSessionID, "two")
        XCTAssertEqual(decision.revealSessionID, "two")
    }

    func testBackgroundResultsKeepCursorWithoutRequestingScroll() {
        let decision = SessionBrowserInteractionPolicy.reduce(
            currentCursorID: "two",
            visibleSessionIDs: ["one", "two", "three"],
            event: .backgroundResultsChanged
        )

        XCTAssertEqual(decision.cursorSessionID, "two")
        XCTAssertNil(decision.revealSessionID)
    }

    func testQueryResultsSelectAndRevealFirstMatch() {
        let decision = SessionBrowserInteractionPolicy.reduce(
            currentCursorID: "old",
            visibleSessionIDs: ["match-one", "match-two"],
            event: .queryResultsChanged
        )

        XCTAssertEqual(decision.cursorSessionID, "match-one")
        XCTAssertEqual(decision.revealSessionID, "match-one")
    }
}
