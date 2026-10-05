import XCTest
@testable import AgentVisorCore

final class NativeMenuReadyAttentionTests: XCTestCase {
    func testReduceMotionKeepsUnopenedAttentionGreenWithoutAnimatingOrAcknowledging() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let unopened = pill(.ready, attentionTier: .ready, activityAt: now, completionUnseen: true)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [unopened], now: now)
        XCTAssertFalse(attention.hasActivePulse(pills: [unopened], now: now, reduceMotion: true))
        XCTAssertEqual(attention.opacity(id: "session", phase: .ready, attentionTier: .ready,
                                        now: now.addingTimeInterval(1.5), reduceMotion: true), 1)
        XCTAssertTrue(attention.isUnopened(unopened))
        XCTAssertEqual(attention.backgroundPulse(for: unopened, now: now, reduceMotion: true), 0)
        XCTAssertEqual(attention.statusStaleness(pill: unopened, now: now.addingTimeInterval(86_400)), 0)
        XCTAssertTrue(attention.hasActivePulse(pills: [unopened], now: now.addingTimeInterval(86_400)))
    }

    func testUnopenedCompletionKeepsBackgroundPulseAndSteadyGreenDotUntilOpened() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let unopened = pill(.ready, attentionTier: .ready, activityAt: completedAt, completionUnseen: true)
        let tomorrow = completedAt.addingTimeInterval(24 * 60 * 60)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [unopened], now: tomorrow)
        XCTAssertTrue(attention.hasActivePulse(pills: [unopened], now: tomorrow))
        XCTAssertEqual(attention.statusStaleness(pill: unopened, now: tomorrow), 0)
        XCTAssertEqual(attention.opacity(
            id: "session", phase: .ready, attentionTier: .ready,
            now: tomorrow.addingTimeInterval(1.5)
        ), 1)
        XCTAssertTrue(attention.isUnopened(unopened))
        XCTAssertEqual(attention.backgroundPulse(for: unopened, now: tomorrow), 0.30, accuracy: 0.001)
        XCTAssertEqual(attention.backgroundPulse(for: unopened, now: tomorrow.addingTimeInterval(1.5)),
                       0.12, accuracy: 0.001)
        XCTAssertEqual(attention.backgroundPulse(for: unopened, now: tomorrow.addingTimeInterval(3)),
                       0.30, accuracy: 0.001)
        let opened = pill(.ready, attentionTier: .acknowledgedReady, activityAt: completedAt)
        attention.present(previousPhases: ["session": .ready], pills: [opened], now: tomorrow)
        XCTAssertFalse(attention.hasActivePulse(pills: [opened], now: tomorrow))
        XCTAssertFalse(attention.isUnopened(opened))
        XCTAssertEqual(attention.backgroundPulse(for: opened, now: tomorrow), 0)
        XCTAssertEqual(attention.statusStaleness(pill: opened, now: tomorrow), 1)
    }

    func testCompletionOutlineRequiresAnUnopenedResultAndClearsWhenWorkResumes() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var attention = NativeMenuReadyAttention()
        let legacyReady = pill(.ready, attentionTier: .ready, activityAt: now)
        attention.present(previousPhases: ["session": .working], pills: [legacyReady], now: now)
        XCTAssertFalse(attention.isUnopened(legacyReady))
        XCTAssertEqual(attention.backgroundPulse(for: legacyReady, now: now), 0)

        let unopened = pill(.ready, attentionTier: .ready, activityAt: now, completionUnseen: true)
        attention.present(previousPhases: ["session": .working], pills: [unopened], now: now)
        XCTAssertTrue(attention.isUnopened(unopened))
        attention.acknowledgeReady(id: "session")
        XCTAssertFalse(attention.isUnopened(unopened))
        XCTAssertEqual(attention.backgroundPulse(for: unopened, now: now), 0)

        let working = pill(.working)
        attention.present(previousPhases: ["session": .ready], pills: [working], now: now)
        XCTAssertFalse(attention.isUnopened(working))
        XCTAssertEqual(attention.backgroundPulse(for: working, now: now), 0)
        attention.present(previousPhases: ["session": .working], pills: [unopened], now: now)
        XCTAssertTrue(attention.isUnopened(unopened))
    }

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

    func testReadyColorFadesWithAgeWithoutAcknowledgingTheCompletion() {
        let activityAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyPill = pill(.ready, activityAt: activityAt)
        let later = activityAt.addingTimeInterval(24 * 60 * 60)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [readyPill], now: later)
        XCTAssertEqual(attention.statusStaleness(pill: readyPill, now: activityAt), 0)
        XCTAssertEqual(attention.statusStaleness(
            pill: readyPill, now: activityAt.addingTimeInterval(21 * 60)
        ), 0.5, accuracy: 0.001)
        XCTAssertEqual(attention.statusStaleness(
            pill: readyPill, now: activityAt.addingTimeInterval(42 * 60)
        ), 1)
        XCTAssertEqual(attention.statusStaleness(pill: readyPill, now: later), 1)
        XCTAssertFalse(attention.isAcknowledged(readyPill))
        XCTAssertFalse(attention.hasActivePulse(pills: [readyPill], now: later))
    }

    func testHistoryAttentionSuppressesPulseWhileReadyPhaseKeepsItsAgeFade() {
        let changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let stalePill = pill(.ready, attentionTier: .history, activityAt: changedAt)
        var attention = NativeMenuReadyAttention()
        attention.present(
            previousPhases: ["session": .working],
            pills: [stalePill],
            now: changedAt
        )

        XCTAssertFalse(attention.hasActivePulse(pills: [stalePill], now: changedAt))
        XCTAssertEqual(
            attention.opacity(
                id: "session", phase: .ready, attentionTier: .history, now: changedAt
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            attention.statusStaleness(
                pill: stalePill, now: changedAt.addingTimeInterval(21 * 60)
            ),
            0.5,
            accuracy: 0.001
        )
    }

    func testHistoryDisplayToReadyAttentionTransitionPulsesAgain() {
        let changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let oldHistory = pill(.ready, attentionTier: .history)
        let freshReady = pill(.ready, attentionTier: .ready)
        var attention = NativeMenuReadyAttention()

        attention.present(
            previousPhases: ["session": NativeMenuDisplayPhase.phase(for: oldHistory)],
            pills: [freshReady],
            now: changedAt
        )

        XCTAssertTrue(attention.hasActivePulse(pills: [freshReady], now: changedAt))
    }

    func testOpeningCompletionKeepsItsColorAgeAndNextCompletionIsUnseen() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let readyPill = pill(.ready, activityAt: now)
        var attention = NativeMenuReadyAttention()
        attention.present(previousPhases: [:], pills: [readyPill], now: now)
        attention.acknowledgeReady(id: "session")
        XCTAssertTrue(attention.isAcknowledged(readyPill))
        XCTAssertEqual(attention.statusStaleness(
            pill: readyPill, now: now.addingTimeInterval(21 * 60)
        ), 0.5, accuracy: 0.001)
        XCTAssertFalse(attention.hasActivePulse(pills: [readyPill], now: now))

        attention.present(previousPhases: ["session": .ready], pills: [pill(.working)], now: now)
        attention.present(previousPhases: ["session": .working], pills: [readyPill], now: now)
        XCTAssertFalse(attention.isAcknowledged(readyPill))
        XCTAssertTrue(attention.hasActivePulse(pills: [readyPill], now: now))
    }

    func testMissingFutureAndNonReadyActivityDoNotInventAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let attention = NativeMenuReadyAttention()
        XCTAssertEqual(attention.statusStaleness(pill: pill(.ready), now: now), 0)
        XCTAssertEqual(attention.statusStaleness(
            pill: pill(.ready, activityAt: now.addingTimeInterval(60)), now: now
        ), 0)
        XCTAssertEqual(attention.statusStaleness(
            pill: pill(.working, activityAt: now.addingTimeInterval(-3600)), now: now
        ), 0)
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
        activityAt: Date? = nil,
        completionUnseen: Bool? = nil
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
            completionUnseen: completionUnseen,
            priority: 0,
            accessibilityLabel: "Session"
        )
    }
}
