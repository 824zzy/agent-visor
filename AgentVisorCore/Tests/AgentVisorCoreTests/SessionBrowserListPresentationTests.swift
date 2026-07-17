import XCTest
@testable import AgentVisorCore

final class SessionBrowserListPresentationTests: XCTestCase {
    func testKeyboardCursorCrossesFromRecentIntoWorkingWithoutLosingHighlight() {
        let selection = SessionBrowserSelection(
            isSearching: false,
            groups: [
                SessionBrowserGroup(section: .working, sessionIds: ["working"]),
                SessionBrowserGroup(section: .recent, sessionIds: ["recent"]),
            ],
            orderedSessionIds: ["working", "recent"]
        )

        let initial = SessionBrowserListPresentation.elements(
            for: selection,
            keyboardCursorSessionID: "recent"
        )
        XCTAssertEqual(highlightedSessionIDs(in: initial), ["recent"])

        let move = SessionBrowserInteractionPolicy.reduce(
            currentCursorID: "recent",
            visibleSessionIDs: selection.orderedSessionIds,
            event: .keyboardMove(offset: -1)
        )
        XCTAssertEqual(move.cursorSessionID, "working")

        let updated = SessionBrowserListPresentation.elements(
            for: selection,
            keyboardCursorSessionID: move.cursorSessionID
        )
        XCTAssertEqual(highlightedSessionIDs(in: updated), ["working"])
    }

    private func highlightedSessionIDs(
        in elements: [SessionBrowserListElement]
    ) -> [String] {
        elements.compactMap { element in
            guard case .session(let sessionID, _, true) = element else { return nil }
            return sessionID
        }
    }
}
