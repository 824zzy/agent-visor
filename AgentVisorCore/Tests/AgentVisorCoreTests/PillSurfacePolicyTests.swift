import XCTest
@testable import AgentVisorCore

final class PillSurfacePolicyTests: XCTestCase {
    func testActiveSessionsOutrankRecentShortcuts() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "recent", phase: .idle, sortDate: now, navigationDate: now),
                candidate(id: "working", phase: .working, sortDate: now.addingTimeInterval(-60))
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["working"])
        XCTAssertEqual(selection.orderedRecentShortcutIds, ["recent"])
        XCTAssertEqual(selection.orderedVisibleIds, ["working", "recent"])
    }

    func testReadyOutranksWorkingRegardlessOfRecency() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "newer-working",
                    phase: .working,
                    sortDate: now,
                    navigationDate: now
                ),
                candidate(id: "older-ready", phase: .ready, sortDate: now.addingTimeInterval(-600))
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["older-ready", "newer-working"])
    }

    func testAcknowledgedReadyFollowsWorkingButRemainsAheadOfRecent() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyDate = now.addingTimeInterval(-60)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "recent", phase: .idle, sortDate: now, navigationDate: now),
                candidate(
                    id: "seen-ready",
                    phase: .ready,
                    sortDate: readyDate,
                    statusDate: readyDate,
                    navigationDate: now.addingTimeInterval(-ReadyAttentionPolicy.defaultPositionHold),
                    readyAcknowledgedAt: now.addingTimeInterval(-ReadyAttentionPolicy.defaultPositionHold)
                ),
                candidate(id: "working", phase: .working, sortDate: now),
                candidate(id: "unseen-ready", phase: .ready, sortDate: now.addingTimeInterval(-120)),
                candidate(id: "attention", phase: .needsAttention, sortDate: now.addingTimeInterval(-180))
            ],
            now: now
        )

        XCTAssertEqual(
            selection.orderedActiveIds,
            ["attention", "unseen-ready", "working", "seen-ready"]
        )
        XCTAssertEqual(selection.orderedRecentShortcutIds, ["recent"])
    }

    func testNavigationDoesNotReorderActiveSessionsWithinPhase() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "recently-opened",
                    phase: .working,
                    sortDate: now.addingTimeInterval(-120),
                    navigationDate: now
                ),
                candidate(
                    id: "newer-transcript",
                    phase: .working,
                    sortDate: now.addingTimeInterval(-10),
                    navigationDate: nil
                )
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["newer-transcript", "recently-opened"])
    }

    func testStatusEntryRecencyDeterminesActiveOrderAfterNavigation() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "recently-opened",
                    phase: .working,
                    sortDate: now,
                    statusDate: now.addingTimeInterval(-120),
                    navigationDate: now.addingTimeInterval(-30)
                ),
                candidate(
                    id: "startup-refreshed",
                    phase: .working,
                    sortDate: now,
                    statusDate: now,
                    navigationDate: nil
                )
            ],
            now: now,
            recentActivityWindow: 1_800
        )

        XCTAssertEqual(selection.orderedActiveIds, ["startup-refreshed", "recently-opened"])
    }

    func testNavigationNeverOverridesFresherActiveStatus() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "old-navigation",
                    phase: .working,
                    sortDate: now,
                    statusDate: now.addingTimeInterval(-120),
                    navigationDate: now.addingTimeInterval(-30)
                ),
                candidate(
                    id: "fresh-status",
                    phase: .working,
                    sortDate: now,
                    statusDate: now.addingTimeInterval(-10),
                    navigationDate: nil
                )
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["fresh-status", "old-navigation"])
    }

    func testActiveOrderUsesStatusDateInsteadOfStreamingActivity() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "streamed-most-recently",
                    phase: .working,
                    sortDate: now,
                    statusDate: now.addingTimeInterval(-120)
                ),
                candidate(
                    id: "entered-status-most-recently",
                    phase: .working,
                    sortDate: now.addingTimeInterval(-30),
                    statusDate: now.addingTimeInterval(-10)
                )
            ],
            now: now
        )

        XCTAssertEqual(
            selection.orderedActiveIds,
            ["entered-status-most-recently", "streamed-most-recently"]
        )
    }

    func testIdleRecentlySelectedSessionBecomesRecentShortcut() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "selected-idle",
                    phase: .idle,
                    sortDate: now.addingTimeInterval(-86_400),
                    navigationDate: now.addingTimeInterval(-30)
                )
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedRecentShortcutIds, ["selected-idle"])
    }

    func testNavigationRecencyStillOrdersRecentShortcuts() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "recently-opened",
                    phase: .idle,
                    sortDate: now.addingTimeInterval(-3_600),
                    navigationDate: now
                ),
                candidate(
                    id: "newer-activity",
                    phase: .idle,
                    sortDate: now.addingTimeInterval(-60)
                )
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedRecentShortcutIds, ["recently-opened", "newer-activity"])
    }

    func testIdleWorkspaceSessionWithoutNavigationRecencyRemainsVisible() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "workspace-idle",
                    phase: .idle,
                    sortDate: now.addingTimeInterval(-7_200),
                    navigationDate: nil
                )
            ],
            now: now,
            recentActivityWindow: 1_800
        )

        XCTAssertEqual(selection.orderedRecentShortcutIds, ["workspace-idle"])
        XCTAssertEqual(selection.orderedVisibleIds, ["workspace-idle"])
    }

    func testRecentShortcutsAreNotCappedByPolicy() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "third", phase: .idle, sortDate: now.addingTimeInterval(-3), navigationDate: now.addingTimeInterval(-3)),
                candidate(id: "first", phase: .idle, sortDate: now.addingTimeInterval(-1), navigationDate: now.addingTimeInterval(-1)),
                candidate(id: "second", phase: .idle, sortDate: now.addingTimeInterval(-2), navigationDate: now.addingTimeInterval(-2))
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedRecentShortcutIds, ["first", "second", "third"])
    }

    func testHiddenEndedAndTitlelessCandidatesAreExcluded() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "hidden", phase: .ready, sortDate: now, isHidden: true),
                candidate(id: "titleless", phase: .ready, sortDate: now, isTitleless: true),
                candidate(id: "ended", phase: .ended, sortDate: now),
                candidate(id: "visible", phase: .ready, sortDate: now)
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedVisibleIds, ["visible"])
    }

    func testStableTieBreakerIsSessionId() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "b", phase: .ready, sortDate: now),
                candidate(id: "a", phase: .ready, sortDate: now)
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["a", "b"])
    }

    private func candidate(
        id: String,
        phase: PillSurfacePhase,
        sortDate: Date,
        statusDate: Date? = nil,
        navigationDate: Date? = nil,
        isHidden: Bool = false,
        isTitleless: Bool = false,
        readyAcknowledgedAt: Date? = nil
    ) -> PillSurfaceCandidate {
        PillSurfaceCandidate(
            id: id,
            phase: phase,
            sortDate: sortDate,
            statusDate: statusDate,
            navigationDate: navigationDate,
            isHidden: isHidden,
            isTitleless: isTitleless,
            readyAcknowledgedAt: readyAcknowledgedAt
        )
    }
}
