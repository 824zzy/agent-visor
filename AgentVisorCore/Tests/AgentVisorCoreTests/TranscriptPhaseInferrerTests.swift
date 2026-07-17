import XCTest
@testable import AgentVisorCore

final class TranscriptPhaseInferrerTests: XCTestCase {
    func testCompletedTranscriptCanResolveStaleObservedApproval() {
        XCTAssertTrue(
            ObservedApprovalRecoveryPolicy.shouldApply(
                currentPhaseIsWaitingForApproval: true,
                inferredPhase: .waitingForInput
            )
        )
    }

    func testRunningTranscriptDoesNotClobberObservedApproval() {
        XCTAssertFalse(
            ObservedApprovalRecoveryPolicy.shouldApply(
                currentPhaseIsWaitingForApproval: true,
                inferredPhase: .processing
            )
        )
    }

    // MARK: - Deterministic (Codex marker) path

    func testTaskCompleteMarkerIsYourTurn() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .completed,
            lastEntryRole: .assistant,
            quiescentSeconds: 0
        )
        XCTAssertEqual(phase, .waitingForInput)
    }

    func testTaskStartedMarkerIsProcessing() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .started,
            lastEntryRole: .user,
            quiescentSeconds: 999
        )
        XCTAssertEqual(phase, .processing)
    }

    func testMarkerWinsOverQuiescenceHeuristicWhenRecent() {
        // Within the stale ceiling, an explicit "started" marker beats the
        // assistant-last heuristic (which would otherwise say "your turn").
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .started,
            lastEntryRole: .assistant,
            quiescentSeconds: 3600,
            staleCeiling: 7200
        )
        XCTAssertEqual(phase, .processing)
    }

    // MARK: - Heuristic (Cursor) path

    func testAssistantQuiescentBeyondThresholdIsYourTurn() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .assistant,
            quiescentSeconds: 10,
            quiescenceThreshold: 6
        )
        XCTAssertEqual(phase, .waitingForInput)
    }

    func testAssistantStillStreamingIsProcessing() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .assistant,
            quiescentSeconds: 2,
            quiescenceThreshold: 6
        )
        XCTAssertEqual(phase, .processing)
    }

    func testQuiescenceBoundaryIsInclusive() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .assistant,
            quiescentSeconds: 6,
            quiescenceThreshold: 6
        )
        XCTAssertEqual(phase, .waitingForInput)
    }

    func testAssistantDormantBeyondStaleCeilingIsIdle() {
        // Finished days ago → dormant, not "your turn".
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .assistant,
            quiescentSeconds: 600_000,
            quiescenceThreshold: 6,
            staleCeiling: 1800
        )
        XCTAssertEqual(phase, .idle)
    }

    func testMarkerCompletedBeyondStaleCeilingIsIdle() {
        // A completed thread quiet past the stale ceiling is dormant, not
        // "your turn" — otherwise a day-old codex thread sorts above live
        // work and pulses its dot. The marker path is no longer exempt.
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .completed,
            lastEntryRole: .assistant,
            quiescentSeconds: 600_000,
            staleCeiling: 1800
        )
        XCTAssertEqual(phase, .idle)
    }

    func testMarkerCompletedWithinStaleCeilingIsYourTurn() {
        // A recently-completed thread IS your turn.
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .completed,
            lastEntryRole: .assistant,
            quiescentSeconds: 60,
            staleCeiling: 1800
        )
        XCTAssertEqual(phase, .waitingForInput)
    }

    func testMarkerStartedBeyondStaleCeilingIsIdle() {
        // A "started" turn silent far past the ceiling is an abandoned/dead
        // run, not active processing.
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .started,
            lastEntryRole: .assistant,
            quiescentSeconds: 600_000,
            staleCeiling: 1800
        )
        XCTAssertEqual(phase, .idle)
    }

    func testUserLastEntryIsProcessing() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .user,
            quiescentSeconds: 999
        )
        XCTAssertEqual(phase, .processing)
    }

    func testDormantUserLastEntryIsIdle() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .user,
            quiescentSeconds: 1_801,
            staleCeiling: 1_800
        )
        XCTAssertEqual(phase, .idle)
    }

    func testToolLastEntryIsProcessing() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .tool,
            quiescentSeconds: 999
        )
        XCTAssertEqual(phase, .processing)
    }

    func testDormantToolLastEntryIsIdle() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .tool,
            quiescentSeconds: 1_801,
            staleCeiling: 1_800
        )
        XCTAssertEqual(phase, .idle)
    }

    func testEmptyTranscriptIsIdle() {
        let phase = TranscriptPhaseInferrer.infer(
            turnMarker: .none,
            lastEntryRole: .none,
            quiescentSeconds: 999
        )
        XCTAssertEqual(phase, .idle)
    }

    // MARK: - ObservedIdleClearPolicy

    func testIdleClearsActiveProcessingPhase() {
        // The regression: an observed Codex thread stuck on `.processing`
        // (currentPhaseIsActive == true) must be cleared when inference
        // says idle — otherwise the green "running" pill is permanent.
        XCTAssertTrue(ObservedIdleClearPolicy.shouldClear(currentPhaseIsActive: true))
    }

    func testIdleDoesNotTouchNonActivePhase() {
        // Already idle / awaiting approval / ended / compacting → leave it.
        XCTAssertFalse(ObservedIdleClearPolicy.shouldClear(currentPhaseIsActive: false))
    }
}
