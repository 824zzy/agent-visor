import XCTest
@testable import AgentVisorCore

final class ObservedHookPhasePolicyTests: XCTestCase {
    func testTranscriptDrivenSessionsIgnoreHookReadyAndIdlePhases() {
        XCTAssertFalse(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .waitingForInput,
            isCurrentlyWaitingForApproval: false
        ))
        XCTAssertFalse(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .idle
        ))
    }

    func testTranscriptDrivenSessionsStillAcceptActiveAndAttentionPhases() {
        XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .processing
        ))
        XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .compacting
        ))
        XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .waitingForApproval
        ))
        XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .ended
        ))
    }

    func testHookDrivenSessionsAcceptAllHookPhases() {
        for phase in ObservedHookPhasePolicy.ReportedPhase.allCases {
            XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
                usesTranscriptPhaseInference: false,
                reportedPhase: phase
            ))
        }
    }

    func testWaitingForInputCanClearObservedApproval() {
        XCTAssertTrue(ObservedHookPhasePolicy.shouldApplyHookPhase(
            usesTranscriptPhaseInference: true,
            reportedPhase: .waitingForInput,
            isCurrentlyWaitingForApproval: true
        ))
    }
}
