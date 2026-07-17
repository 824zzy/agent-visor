import XCTest
@testable import AgentVisorCore

final class PillMovementGracePolicyTests: XCTestCase {
    func testFirstNavigationDefersMovementForTwoSeconds() {
        let navigationAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let pending = PillMovementGracePolicy.pendingMove(
            existing: nil,
            navigationAt: navigationAt
        )

        XCTAssertEqual(pending.navigationDate, navigationAt)
        XCTAssertEqual(
            pending.deadline,
            navigationAt.addingTimeInterval(ReadyAttentionPolicy.defaultPositionHold)
        )
        XCTAssertFalse(PillMovementGracePolicy.isReadyToCommit(
            pending,
            now: pending.deadline.addingTimeInterval(-0.001)
        ))
        XCTAssertTrue(PillMovementGracePolicy.isReadyToCommit(
            pending,
            now: pending.deadline
        ))
    }

    func testRepeatedNavigationKeepsFirstDeadlineAndLatestRecency() {
        let firstNavigation = Date(timeIntervalSinceReferenceDate: 1_000)
        let repeatedNavigation = firstNavigation.addingTimeInterval(1)
        let first = PillMovementGracePolicy.pendingMove(
            existing: nil,
            navigationAt: firstNavigation
        )

        let updated = PillMovementGracePolicy.pendingMove(
            existing: first,
            navigationAt: repeatedNavigation
        )

        XCTAssertEqual(updated.deadline, first.deadline)
        XCTAssertEqual(updated.navigationDate, repeatedNavigation)
    }
}
