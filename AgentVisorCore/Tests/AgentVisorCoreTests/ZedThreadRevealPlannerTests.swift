import XCTest
@testable import AgentVisorCore

final class ZedThreadRevealPlannerTests: XCTestCase {
    func testQueryCollapsesToSingleLineAndTrims() {
        XCTAssertEqual(
            ZedThreadRevealPlanner.query(forTitle: "  See the\nscreenshot  "),
            "See the screenshot"
        )
    }

    func testQueryTruncatesLongTitles() {
        let title = String(repeating: "a", count: 120)
        let query = ZedThreadRevealPlanner.query(forTitle: title)
        XCTAssertEqual(query?.count, ZedThreadRevealPlanner.maximumQueryLength)
    }

    func testNoQueryWithoutUsableTitle() {
        // Zed rows start with an empty title; typing nothing would leave
        // the list unfiltered and Confirm would open an arbitrary thread.
        XCTAssertNil(ZedThreadRevealPlanner.query(forTitle: nil))
        XCTAssertNil(ZedThreadRevealPlanner.query(forTitle: ""))
        XCTAssertNil(ZedThreadRevealPlanner.query(forTitle: "  \n "))
    }

    func testPlanOrdersFocusTypeSelectConfirm() {
        let plan = ZedThreadRevealPlanner.plan(title: "pi-test-2", settleDelay: 0.2)
        XCTAssertEqual(plan, [
            .key(.openCommandPalette),
            .delay(0.2),
            .key(.selectAll),
            .key(.deleteBackward),
            .text(ZedThreadRevealPlanner.focusSidebarAction),
            .delay(0.2),
            .key(.confirm),
            .delay(0.2),
            .key(.focusSidebarFilter),
            .delay(0.2),
            .key(.selectAll),
            .key(.deleteBackward),
            .text("pi-test-2"),
            .delay(0.2),
            .key(.selectNext),
            .delay(0.2),
            .key(.confirm)
        ])
    }

    func testPlanIncludesSelectNextBecauseFilteringClearsSelection() {
        // Zed's sidebar calls `selection.take()` on every filter edit, so
        // Confirm alone is a no-op.
        let plan = ZedThreadRevealPlanner.plan(title: "hi")
        let keys = plan.compactMap { step -> ZedRevealKey? in
            if case let .key(key) = step { return key }
            return nil
        }
        XCTAssertEqual(keys, [
            .openCommandPalette,
            .selectAll,
            .deleteBackward,
            .confirm,
            .focusSidebarFilter,
            .selectAll,
            .deleteBackward,
            .selectNext,
            .confirm
        ])
    }

    func testEmptyPlanWhenTitleIsUnusable() {
        XCTAssertTrue(ZedThreadRevealPlanner.plan(title: nil).isEmpty)
        XCTAssertTrue(ZedThreadRevealPlanner.plan(title: " ").isEmpty)
    }

    func testCleanupPlanReestablishesFocusBeforeClearingFilter() {
        XCTAssertEqual(ZedThreadRevealPlanner.cleanupPlan(settleDelay: 0.1), [
            .key(.openCommandPalette),
            .delay(0.1),
            .key(.selectAll),
            .key(.deleteBackward),
            .text(ZedThreadRevealPlanner.focusSidebarAction),
            .delay(0.1),
            .key(.confirm),
            .delay(0.1),
            .key(.focusSidebarFilter),
            .delay(0.1),
            .key(.selectAll),
            .key(.deleteBackward)
        ])
    }
}

final class ZedThreadRevealVerifierTests: XCTestCase {
    private let targetHex = "B3713C97F48B4B6DB158EDD471662DD2"
    private let targetUUID = "b3713c97-f48b-4b6d-b158-edd471662dd2"
    private let targetSession = "019fd5f3-cc38-7673-ae09-68833af93ad0"
    private let otherUUID = "ef4b116d-57cd-408c-bf02-8ad5931b59ad"

    func testPersistedTargetThreadIsRevealedAcrossHexAndUUIDForms() {
        XCTAssertEqual(
            ZedThreadRevealVerifier.outcome(
                targetThreadID: targetHex,
                targetSessionID: targetSession,
                selection: ZedThreadSelection(threadID: targetUUID, sessionID: targetSession)
            ),
            .revealed
        )
    }

    func testAlreadySelectedTargetStillCountsAsRevealed() {
        let selection = ZedThreadSelection(threadID: targetUUID, sessionID: targetSession)
        XCTAssertEqual(
            ZedThreadRevealVerifier.outcome(
                targetThreadID: targetHex,
                targetSessionID: targetSession,
                selection: selection
            ),
            .revealed
        )
    }

    func testSessionIDFallbackVerifiesOlderPanelPayload() {
        XCTAssertEqual(
            ZedThreadRevealVerifier.outcome(
                targetThreadID: targetHex,
                targetSessionID: targetSession,
                selection: ZedThreadSelection(threadID: nil, sessionID: targetSession)
            ),
            .revealed
        )
    }

    func testChangedNeighbourSelectionIsReportedHonestly() {
        XCTAssertEqual(
            ZedThreadRevealVerifier.outcome(
                targetThreadID: targetHex,
                targetSessionID: targetSession,
                selection: ZedThreadSelection(threadID: otherUUID, sessionID: "other-session")
            ),
            .openedDifferentThread(threadID: otherUUID)
        )
    }

    func testMissingPanelReceiptIsUnverified() {
        XCTAssertEqual(
            ZedThreadRevealVerifier.outcome(
                targetThreadID: targetHex,
                targetSessionID: targetSession,
                selection: nil
            ),
            .unverified
        )
    }
}
