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

    private func pill(_ phase: NativeHelperPillPhase) -> NativeHelperPill {
        NativeHelperPill(
            id: "session",
            title: "Session",
            phase: phase,
            priority: 0,
            accessibilityLabel: "Session"
        )
    }
}
