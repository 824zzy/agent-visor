import XCTest
@testable import AgentVisorCore

final class NativeMenuReadyAttentionTests: XCTestCase {
    func testObservedReadyTransitionPulsesWithReleasedTiming() {
        let changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var attention = NativeMenuReadyAttention()
        attention.present(
            previousPhases: ["session": .working],
            pills: [pill(.ready)],
            now: changedAt
        )

        XCTAssertTrue(attention.hasActivePulse(pills: [pill(.ready)], now: changedAt))
        XCTAssertEqual(
            attention.opacity(id: "session", phase: .ready, now: changedAt),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            attention.opacity(id: "session", phase: .ready, now: changedAt.addingTimeInterval(0.75)),
            0.35,
            accuracy: 0.001
        )
    }

    func testInitialReadySnapshotDoesNotInventACompletion() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [pill(.ready)], now: now)

        XCTAssertFalse(attention.hasActivePulse(pills: [pill(.ready)], now: now))
        XCTAssertEqual(attention.opacity(id: "session", phase: .ready, now: now), 1)
    }

    func testRepeatedReadySnapshotDoesNotRestartExpiredPulse() {
        let changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let expiredAt = changedAt.addingTimeInterval(ReadyAttentionPolicy.defaultPulseWindow)
        var attention = NativeMenuReadyAttention()
        attention.present(
            previousPhases: ["session": .working],
            pills: [pill(.ready)],
            now: changedAt
        )
        attention.present(
            previousPhases: ["session": .ready],
            pills: [pill(.ready)],
            now: expiredAt
        )

        XCTAssertFalse(attention.hasActivePulse(pills: [pill(.ready)], now: expiredAt))
    }

    func testReadyActivationAcknowledgesPulse() {
        let changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var attention = NativeMenuReadyAttention()
        attention.present(
            previousPhases: ["session": .working],
            pills: [pill(.ready)],
            now: changedAt
        )
        attention.acknowledgeReady(id: "session")

        XCTAssertEqual(attention.acknowledgedReadyIDs, ["session"])
        XCTAssertFalse(attention.hasActivePulse(pills: [pill(.ready)], now: changedAt))
        XCTAssertEqual(attention.opacity(id: "session", phase: .ready, now: changedAt), 1)
    }

    func testPresentedSharedAttentionSynchronizesAcknowledgment() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var attention = NativeMenuReadyAttention()

        attention.present(
            previousPhases: ["session": .ready],
            pills: [pill(.ready, attentionTier: .acknowledgedReady)],
            now: now
        )
        XCTAssertEqual(attention.acknowledgedReadyIDs, ["session"])

        attention.present(
            previousPhases: ["session": .ready],
            pills: [pill(.ready, attentionTier: .ready)],
            now: now
        )
        XCTAssertEqual(attention.acknowledgedReadyIDs, [])
    }

    func testUnseenCompletionDoesNotFadeWithAge() {
        let activityAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyPill = pill(.ready, activityAt: activityAt)
        let later = activityAt.addingTimeInterval(24 * 60 * 60)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [readyPill], now: later)
        XCTAssertFalse(attention.isAcknowledged(readyPill))
        XCTAssertFalse(attention.hasActivePulse(pills: [readyPill], now: later))
    }

    func testOpeningCompletionMutesItImmediatelyAndNextCompletionIsUnseen() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyPill = pill(.ready, activityAt: now)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [readyPill], now: now)
        attention.acknowledgeReady(id: "session")
        XCTAssertTrue(attention.isAcknowledged(readyPill))

        attention.present(previousPhases: ["session": .ready], pills: [pill(.working)], now: now)
        attention.present(previousPhases: ["session": .working], pills: [readyPill], now: now)
        XCTAssertFalse(attention.isAcknowledged(readyPill))
        XCTAssertTrue(attention.hasActivePulse(pills: [readyPill], now: now))
    }

    func testPresentedAcknowledgmentWinsEvenWhenHelperMissedTheReadyBoundary() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyPill = pill(.ready, attentionTier: .acknowledgedReady, activityAt: now)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: ["session": .working], pills: [readyPill], now: now)
        XCTAssertEqual(attention.acknowledgedReadyIDs, ["session"])
        XCTAssertTrue(attention.isAcknowledged(readyPill))
        XCTAssertFalse(attention.hasActivePulse(pills: [readyPill], now: now))
    }

    private func pill(
        _ phase: NativeHelperPillPhase,
        attentionTier: NativeHelperSessionAttentionTier? = nil,
        activityAt: Date? = nil
    ) -> NativeHelperPill {
        NativeHelperPill(
            id: "session",
            title: "Session",
            inspector: activityAt.map {
                NativeHelperSessionInspector(
                    status: "Ready",
                    runtimeItems: ["Pi · Ghostty"],
                    detailRows: [],
                    projectPath: "~/Codes/agent-visor",
                    activityAt: $0.formatted(.iso8601),
                    context: nil
                )
            },
            phase: phase,
            attentionTier: attentionTier,
            priority: 0,
            accessibilityLabel: "Session"
        )
    }
}
