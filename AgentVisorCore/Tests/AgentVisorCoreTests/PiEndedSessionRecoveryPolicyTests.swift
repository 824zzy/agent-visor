import XCTest
@testable import AgentVisorCore

final class PiEndedSessionRecoveryPolicyTests: XCTestCase {
    func testRecoversEndedLiveSessionWhenTranscriptStartsAnotherTurn() {
        XCTAssertTrue(PiEndedSessionRecoveryPolicy.shouldRecover(
            isEnded: true,
            hasLiveProcess: true,
            transcriptModifiedAt: 201,
            endedObservedAt: 200,
            turnMarker: .started
        ))
    }

    func testDoesNotRecoverACompletedSessionAfterShutdown() {
        XCTAssertFalse(PiEndedSessionRecoveryPolicy.shouldRecover(
            isEnded: true,
            hasLiveProcess: true,
            transcriptModifiedAt: 201,
            endedObservedAt: 200,
            turnMarker: .completed
        ))
    }

    func testRequiresPostEndTranscriptEvidenceAndLiveProcess() {
        XCTAssertFalse(PiEndedSessionRecoveryPolicy.shouldRecover(
            isEnded: true,
            hasLiveProcess: true,
            transcriptModifiedAt: 200,
            endedObservedAt: 200,
            turnMarker: .started
        ))
        XCTAssertFalse(PiEndedSessionRecoveryPolicy.shouldRecover(
            isEnded: true,
            hasLiveProcess: false,
            transcriptModifiedAt: 201,
            endedObservedAt: 200,
            turnMarker: .started
        ))
    }
}
