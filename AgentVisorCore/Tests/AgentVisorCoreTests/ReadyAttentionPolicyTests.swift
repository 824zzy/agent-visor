import XCTest
@testable import AgentVisorCore

final class ReadyAttentionPolicyTests: XCTestCase {
    func testFreshUnacknowledgedReadyCompletionPulses() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: nil,
            now: phaseChangedAt.addingTimeInterval(60)
        ))
    }

    func testOpeningAfterReadyTransitionAcknowledgesCompletion() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: phaseChangedAt.addingTimeInterval(30),
            now: phaseChangedAt.addingTimeInterval(60)
        ))
    }

    func testRepeatedNavigationPreservesFirstAcknowledgmentForCurrentReadyTransition() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstAcknowledgment = phaseChangedAt.addingTimeInterval(10)
        let repeatedNavigation = phaseChangedAt.addingTimeInterval(30)

        let acknowledgment = ReadyAttentionPolicy.acknowledgmentDateAfterNavigation(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            existingAcknowledgedAt: firstAcknowledgment,
            navigationAt: repeatedNavigation
        )

        XCTAssertEqual(acknowledgment, firstAcknowledgment)
    }

    func testLaterReadyTransitionRecordsANewAcknowledgment() {
        let previousAcknowledgment = Date(timeIntervalSinceReferenceDate: 1_000)
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let navigationAt = phaseChangedAt.addingTimeInterval(10)

        let acknowledgment = ReadyAttentionPolicy.acknowledgmentDateAfterNavigation(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            existingAcknowledgedAt: previousAcknowledgment,
            navigationAt: navigationAt
        )

        XCTAssertEqual(acknowledgment, navigationAt)
    }

    func testLaterReadyTransitionPulsesAgain() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 2_000)

        XCTAssertTrue(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: phaseChangedAt.addingTimeInterval(-30),
            now: phaseChangedAt.addingTimeInterval(60)
        ))
    }

    func testAttentionPulseExpiresAfterSevenMinutes() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: nil,
            now: phaseChangedAt.addingTimeInterval(420)
        ))
    }

    func testOpeningReadySessionKeepsPillAheadOfWorkingDuringPositionHold() {
        let acknowledgedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let clickedPhaseDate = acknowledgedAt.addingTimeInterval(-120)
        let duringHold = acknowledgedAt.addingTimeInterval(1.999)

        let before = PillSurfacePolicy.select(
            candidates: [
                candidate(id: "clicked", statusDate: clickedPhaseDate),
                candidate(id: "working", phase: .working, statusDate: acknowledgedAt.addingTimeInterval(-30))
            ],
            now: acknowledgedAt
        )
        let after = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "clicked",
                    statusDate: clickedPhaseDate,
                    navigationDate: acknowledgedAt,
                    readyAcknowledgedAt: acknowledgedAt
                ),
                candidate(id: "working", phase: .working, statusDate: acknowledgedAt.addingTimeInterval(-30))
            ],
            now: duringHold
        )

        XCTAssertEqual(before.orderedActiveIds, ["clicked", "working"])
        XCTAssertEqual(after.orderedActiveIds, before.orderedActiveIds)
        XCTAssertFalse(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: clickedPhaseDate,
            acknowledgedAt: acknowledgedAt,
            now: duringHold
        ))
    }

    func testAcknowledgedReadyMovesBelowWorkingWhenPositionHoldExpires() {
        let acknowledgedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let clickedPhaseDate = acknowledgedAt.addingTimeInterval(-120)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "clicked",
                    statusDate: clickedPhaseDate,
                    navigationDate: acknowledgedAt,
                    readyAcknowledgedAt: acknowledgedAt
                ),
                candidate(id: "working", phase: .working, statusDate: acknowledgedAt.addingTimeInterval(-30))
            ],
            now: acknowledgedAt.addingTimeInterval(ReadyAttentionPolicy.defaultPositionHold)
        )

        XCTAssertEqual(selection.orderedActiveIds, ["working", "clicked"])
    }

    func testRepeatedNavigationDoesNotPromoteAcknowledgedReadyAboveWorking() {
        let phaseChangedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let firstAcknowledgment = phaseChangedAt.addingTimeInterval(10)
        let repeatedNavigation = phaseChangedAt.addingTimeInterval(30)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "clicked-again",
                    statusDate: phaseChangedAt,
                    navigationDate: repeatedNavigation,
                    readyAcknowledgedAt: firstAcknowledgment
                ),
                candidate(id: "working", phase: .working, statusDate: repeatedNavigation)
            ],
            now: repeatedNavigation
        )

        XCTAssertEqual(selection.orderedActiveIds, ["working", "clicked-again"])
    }

    func testLaterReadyTransitionReturnsPillAboveWorking() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let previousNavigation = now.addingTimeInterval(-120)
        let newReadyPhaseDate = now.addingTimeInterval(-30)

        let selection = PillSurfacePolicy.select(
            candidates: [
                candidate(
                    id: "ready-again",
                    statusDate: newReadyPhaseDate,
                    navigationDate: previousNavigation,
                    readyAcknowledgedAt: previousNavigation
                ),
                candidate(id: "working", phase: .working, statusDate: now)
            ],
            now: now
        )

        XCTAssertEqual(selection.orderedActiveIds, ["ready-again", "working"])
        XCTAssertTrue(ReadyAttentionPolicy.shouldPulse(
            isReady: true,
            phaseChangedAt: newReadyPhaseDate,
            acknowledgedAt: previousNavigation,
            now: now
        ))
    }

    private func candidate(
        id: String,
        phase: PillSurfacePhase = .ready,
        statusDate: Date,
        navigationDate: Date? = nil,
        readyAcknowledgedAt: Date? = nil
    ) -> PillSurfaceCandidate {
        PillSurfaceCandidate(
            id: id,
            phase: phase,
            sortDate: statusDate,
            statusDate: statusDate,
            navigationDate: navigationDate,
            isHidden: false,
            isTitleless: false,
            readyAcknowledgedAt: readyAcknowledgedAt
        )
    }
}
