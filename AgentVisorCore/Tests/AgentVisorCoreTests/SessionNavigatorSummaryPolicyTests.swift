import XCTest
@testable import AgentVisorCore

final class SessionNavigatorSummaryPolicyTests: XCTestCase {
    func testCountsRowsByStateSection() {
        let summary = SessionNavigatorSummaryPolicy.summary(
            sectionCounts: [
                .needsAttention: 1,
                .ready: 2,
                .working: 3,
                .recent: 4,
            ]
        )

        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.ready, 2)
        XCTAssertEqual(summary.working, 3)
        XCTAssertEqual(summary.recent, 4)
        XCTAssertEqual(summary.total, 10)
    }

    func testHeaderOmitsReadyWhenReadyCountIsZero() {
        let summary = SessionNavigatorSummaryPolicy.summary(
            sectionCounts: [
                .needsAttention: 0,
                .ready: 0,
                .working: 0,
                .recent: 11,
            ]
        )

        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.headerText(for: summary),
            "0 attention · 0 working · 11 recent"
        )
    }

    func testHeaderShowsReadyWhenReadyCountIsNonZero() {
        let summary = SessionNavigatorSummaryPolicy.summary(
            sectionCounts: [
                .needsAttention: 0,
                .ready: 2,
                .working: 1,
                .recent: 8,
            ]
        )

        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.headerText(for: summary),
            "0 attention · 2 ready · 1 working · 8 recent"
        )
    }

    func testOverflowCopySeparatesQuickSearchFromTheFullBrowser() {
        XCTAssertEqual(SessionNavigatorSummaryPolicy.overflowTitle, "More Sessions")
        XCTAssertEqual(SessionNavigatorSummaryPolicy.searchTitle, "Search Sessions")
        XCTAssertEqual(SessionNavigatorSummaryPolicy.settingsLabel, "Settings...")
        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.searchPlaceholder(totalSessionCount: 15),
            "Search all 15 sessions"
        )
        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.searchPlaceholder(totalSessionCount: 1),
            "Search all 1 session"
        )
        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.searchHeaderText(matchCount: 2, totalSessionCount: 14),
            "2 matches · 14 sessions"
        )
        XCTAssertEqual(
            SessionNavigatorSummaryPolicy.searchHeaderText(matchCount: 1, totalSessionCount: 1),
            "1 match · 1 session"
        )
        XCTAssertEqual(SessionNavigatorSummaryPolicy.openBrowserLabel, "Open Agent Sessions")
    }
}
