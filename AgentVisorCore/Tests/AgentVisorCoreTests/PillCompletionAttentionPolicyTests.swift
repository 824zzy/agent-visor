import XCTest
@testable import AgentVisorCore

final class PillCompletionAttentionPolicyTests: XCTestCase {
    func testUnseenCompletionRemainsUnseenAfterAnOvernightAbsence() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            PillCompletionAttentionPolicy.state(
                completedAt: completedAt,
                acknowledgedAt: nil
            ),
            .unseen
        )
        XCTAssertFalse(
            PillCompletionAttentionPolicy.shouldPulse(
                completedAt: completedAt,
                acknowledgedAt: nil,
                now: completedAt.addingTimeInterval(12 * 60 * 60)
            )
        )
    }

    func testActivationAcknowledgesTheCurrentCompletion() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let activatedAt = completedAt.addingTimeInterval(60)

        let acknowledgedAt = PillCompletionAttentionPolicy.acknowledgmentDateAfterActivation(
            completedAt: completedAt,
            existingAcknowledgedAt: nil,
            activatedAt: activatedAt
        )

        XCTAssertEqual(acknowledgedAt, activatedAt)
        XCTAssertEqual(
            PillCompletionAttentionPolicy.state(
                completedAt: completedAt,
                acknowledgedAt: acknowledgedAt
            ),
            .seen
        )
    }

    func testLaterCompletionBecomesUnseenAgain() {
        let firstCompletion = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstAcknowledgment = firstCompletion.addingTimeInterval(60)
        let laterCompletion = firstAcknowledgment.addingTimeInterval(60)

        XCTAssertEqual(
            PillCompletionAttentionPolicy.state(
                completedAt: laterCompletion,
                acknowledgedAt: firstAcknowledgment
            ),
            .unseen
        )
    }

    func testSessionWithoutARecordedCompletionHasNoCompletionAttention() {
        XCTAssertEqual(
            PillCompletionAttentionPolicy.state(
                completedAt: nil,
                acknowledgedAt: nil
            ),
            .none
        )
    }

    func testFirstReadyObservationRecordsACompletion() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            PillCompletionObservationPolicy.completionDateAfterObservation(
                isReady: true,
                previousObservationWasReady: nil,
                observedCompletionAt: observedAt,
                existingCompletedAt: nil
            ),
            observedAt
        )
    }

    func testRestartOnTheSameCompletionKeepsItsPersistedIdentity() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            PillCompletionObservationPolicy.completionDateAfterObservation(
                isReady: true,
                previousObservationWasReady: nil,
                observedCompletionAt: completedAt,
                existingCompletedAt: completedAt
            ),
            completedAt
        )
    }

    func testLaterReadyEpisodeReplacesThePersistedCompletion() {
        let firstCompletion = Date(timeIntervalSinceReferenceDate: 1_000)
        let laterCompletion = firstCompletion.addingTimeInterval(600)

        XCTAssertEqual(
            PillCompletionObservationPolicy.completionDateAfterObservation(
                isReady: true,
                previousObservationWasReady: false,
                observedCompletionAt: laterCompletion,
                existingCompletedAt: firstCompletion
            ),
            laterCompletion
        )
    }

    func testLaterCompletionObservedAfterRestartIsNotLost() {
        let firstCompletion = Date(timeIntervalSinceReferenceDate: 1_000)
        let laterCompletion = firstCompletion.addingTimeInterval(600)

        XCTAssertEqual(
            PillCompletionObservationPolicy.completionDateAfterObservation(
                isReady: true,
                previousObservationWasReady: nil,
                observedCompletionAt: laterCompletion,
                existingCompletedAt: firstCompletion
            ),
            laterCompletion
        )
    }
}
