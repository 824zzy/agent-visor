import XCTest
@testable import AgentVisorCore

final class HookSessionLifecyclePolicyTests: XCTestCase {
    func testSessionStartIsIdleUntilARealTurnBeginsOrCompletes() {
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "SessionStart",
                reportedStatus: "waiting_for_input",
                isTerminalLifecycleStatus: false
            ),
            .idle
        )
    }

    func testHookReadyExpiresIntoRecentAfterTheStaleCeiling() {
        XCTAssertTrue(HookReadyExpirationPolicy.shouldExpire(
            isWaitingForInput: true,
            hasHookEvidence: true,
            observedAt: 100,
            now: 1_901,
            staleCeiling: 1_800
        ))
    }

    func testCompletedTurnStillReportsWaitingForInput() {
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "Stop",
                reportedStatus: "waiting_for_input",
                isTerminalLifecycleStatus: false
            ),
            .waitingForInput
        )
    }

    func testSubagentStopKeepsTheParentTurnProcessing() {
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "SubagentStop",
                reportedStatus: "waiting_for_input",
                isTerminalLifecycleStatus: false
            ),
            .processing
        )
    }

    func testStopFailureEndsTheTurnWithoutLeavingItWorking() {
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "StopFailure",
                reportedStatus: "unknown",
                isTerminalLifecycleStatus: false
            ),
            .waitingForInput
        )
    }

    func testParentTurnLifecycleDoesNotBecomeReadyWhenOnlyASubagentStops() {
        let events = [
            ("SessionStart", "idle"),
            ("UserPromptSubmit", "processing"),
            ("SubagentStop", "waiting_for_input"),
            ("Stop", "waiting_for_input"),
        ]

        XCTAssertEqual(
            events.map {
                HookSessionLifecyclePolicy.phase(
                    event: $0.0,
                    reportedStatus: $0.1,
                    isTerminalLifecycleStatus: false
                )
            },
            [.idle, .processing, .processing, .waitingForInput]
        )
    }

    func testPostCompactResumesThePhaseReportedByTheHook() {
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "PostCompact",
                reportedStatus: "processing",
                isTerminalLifecycleStatus: false
            ),
            .processing
        )
        XCTAssertEqual(
            HookSessionLifecyclePolicy.phase(
                event: "PostCompact",
                reportedStatus: "waiting_for_input",
                isTerminalLifecycleStatus: false
            ),
            .waitingForInput
        )
    }

    func testReadyDoesNotExpireAtTheBoundaryOrFromTranscriptEvidence() {
        XCTAssertFalse(HookReadyExpirationPolicy.shouldExpire(
            isWaitingForInput: true,
            hasHookEvidence: true,
            observedAt: 100,
            now: 1_900,
            staleCeiling: 1_800
        ))
        XCTAssertFalse(HookReadyExpirationPolicy.shouldExpire(
            isWaitingForInput: true,
            hasHookEvidence: false,
            observedAt: 100,
            now: 10_000,
            staleCeiling: 1_800
        ))
    }
}
