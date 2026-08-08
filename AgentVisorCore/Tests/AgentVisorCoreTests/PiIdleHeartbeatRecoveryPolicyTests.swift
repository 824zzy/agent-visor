import XCTest
@testable import AgentVisorCore

final class PiIdleHeartbeatRecoveryPolicyTests: XCTestCase {
    private let now: TimeInterval = 10_000

    func testOrdinaryHeartbeatStaysPhaseNeutral() {
        // The runtime is working: the heartbeat must not touch the row.
        XCTAssertEqual(
            outcome(reportedIdle: false, currentPhaseIsActive: true),
            .none
        )
        // Nothing to repair: the row is not showing work.
        XCTAssertEqual(
            outcome(reportedIdle: true, currentPhaseIsActive: false),
            .none
        )
    }

    func testNonHeartbeatEventsAreNotRecoveryEvidence() {
        XCTAssertEqual(
            outcome(isHeartbeat: false, reportedIdle: true, currentPhaseIsActive: true),
            .none
        )
    }

    func testMissingIdleFlagPreservesPreviousBehavior() {
        // A live Pi process still running an older copy of the bundled
        // extension reports no flag; it must keep the phase-neutral contract
        // instead of being treated as idle.
        XCTAssertEqual(
            outcome(reportedIdle: nil, currentPhaseIsActive: true),
            .none
        )
    }

    func testFreshlyDroppedCompletionRepublishesReady() {
        // The dropped Stop is recovered within a heartbeat interval, so the
        // user still gets the Ready episode the completion earned.
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: now - 10
            ),
            .ready
        )
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: now - PiIdleHeartbeatRecoveryPolicy.readyGraceWindow
            ),
            .ready
        )
    }

    func testLongStuckWorkResolvesQuietlyWithoutLateAttention() {
        // The observed regression: a turn that ended 20 minutes ago. Clear the
        // wrong Working pill, but do not ring a notification for old news.
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: now - 20 * 60
            ),
            .idle
        )
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: now - (PiIdleHeartbeatRecoveryPolicy.readyGraceWindow + 1)
            ),
            .idle
        )
    }

    func testUnreadableCompletionBoundaryStillClearsWorkQuietly() {
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: nil
            ),
            .idle
        )
    }

    func testFutureTranscriptTimestampIsTreatedAsFresh() {
        XCTAssertEqual(
            outcome(
                reportedIdle: true,
                currentPhaseIsActive: true,
                transcriptModifiedAt: now + 5
            ),
            .ready
        )
    }

    func testCompletionBoundaryIsResolvedOnlyForRepairableRows() {
        XCTAssertTrue(PiIdleHeartbeatRecoveryPolicy.shouldResolveCompletionBoundary(
            isHeartbeat: true,
            reportedIdle: true,
            currentPhaseIsActive: true
        ))
        // Every other combination must skip the filesystem probe entirely.
        XCTAssertFalse(PiIdleHeartbeatRecoveryPolicy.shouldResolveCompletionBoundary(
            isHeartbeat: true,
            reportedIdle: true,
            currentPhaseIsActive: false
        ))
        XCTAssertFalse(PiIdleHeartbeatRecoveryPolicy.shouldResolveCompletionBoundary(
            isHeartbeat: true,
            reportedIdle: nil,
            currentPhaseIsActive: true
        ))
        XCTAssertFalse(PiIdleHeartbeatRecoveryPolicy.shouldResolveCompletionBoundary(
            isHeartbeat: false,
            reportedIdle: true,
            currentPhaseIsActive: true
        ))
    }

    func testRecoveryNeverPromotesAnIdleRowToWorking() {
        // Scope guard: the policy is one-directional. A heartbeat sampled just
        // before a completion cannot resurrect Working after the real Stop.
        for reportedIdle in [true, false, nil] as [Bool?] {
            XCTAssertEqual(
                outcome(reportedIdle: reportedIdle, currentPhaseIsActive: false),
                .none
            )
        }
    }

    private func outcome(
        isHeartbeat: Bool = true,
        reportedIdle: Bool?,
        currentPhaseIsActive: Bool,
        transcriptModifiedAt: TimeInterval? = nil
    ) -> PiIdleHeartbeatRecoveryPolicy.Outcome {
        PiIdleHeartbeatRecoveryPolicy.outcome(
            isHeartbeat: isHeartbeat,
            reportedIdle: reportedIdle,
            currentPhaseIsActive: currentPhaseIsActive,
            transcriptModifiedAt: transcriptModifiedAt,
            now: now
        )
    }
}
