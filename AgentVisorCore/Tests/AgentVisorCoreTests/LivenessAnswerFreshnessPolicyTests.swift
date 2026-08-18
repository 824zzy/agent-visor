import XCTest
@testable import AgentVisorCore

/// The sweep now waits for its liveness answer away from the threads that serve
/// the rest of the app, so other work runs during that wait. These tests pin what
/// makes the answer stale, because acting on a stale answer would grey out a
/// session that just reported work.
final class LivenessAnswerFreshnessPolicyTests: XCTestCase {
    private let asked = SessionStateFixture.make(
        pid: 4242,
        phase: .idle,
        lastActivity: Date(timeIntervalSince1970: 1_700_000_000)
    )

    func testAnUnchangedRowKeepsItsAnswer() {
        XCTAssertTrue(
            LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: asked),
            "With nothing changed, the answer describes this row and the sweep must act on it."
        )
    }

    func testNewerActivityMakesTheAnswerStale() {
        var current = asked
        current.lastActivity = asked.lastActivity.addingTimeInterval(0.4)
        XCTAssertFalse(
            LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current),
            "Something reported after we asked, so the row is alive."
        )
    }

    func testOlderOrEqualActivityKeepsTheAnswer() {
        // Equal is the normal case: nothing touched the row while we asked.
        var current = asked
        current.lastActivity = asked.lastActivity
        XCTAssertTrue(LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current))

        // Older should not happen, and it is not evidence of life either.
        current.lastActivity = asked.lastActivity.addingTimeInterval(-5)
        XCTAssertTrue(LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current))
    }

    func testANewProcessMakesTheAnswerStale() {
        // A row that rebound to a live process is the exact case the sweep must
        // not end: the death answer was about the process that went away.
        var current = asked
        current.pid = 5555
        XCTAssertFalse(LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current))
    }

    func testALostProcessMakesTheAnswerStale() {
        var current = asked
        current.pid = nil
        XCTAssertFalse(
            LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current),
            "The row no longer names the process the answer was about."
        )
    }

    func testANewPhaseMakesTheAnswerStale() {
        // A hook can set a phase without moving activity. Stronger evidence has
        // already spoken, so the sweep waits for the next round.
        let approval = PermissionContext(
            toolUseId: "tooluse_123",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        for phase in [
            SessionPhase.processing,
            .waitingForApproval(approval),
            .compacting,
            .waitingForInput
        ] {
            var current = asked
            current.phase = phase
            XCTAssertFalse(
                LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current),
                "Phase \(phase) arrived after we asked."
            )
        }
    }

    func testARowAlreadyEndedNeedsNoSecondEnding() {
        var current = asked
        current.phase = .ended
        XCTAssertFalse(LivenessAnswerFreshnessPolicy.stillApplies(asked: asked, current: current))
    }
}
