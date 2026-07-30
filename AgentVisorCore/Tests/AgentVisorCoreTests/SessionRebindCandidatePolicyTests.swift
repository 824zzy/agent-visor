import XCTest
@testable import AgentVisorCore

final class SessionRebindCandidatePolicyTests: XCTestCase {
    func testEndedResurrectionExcludesCurrentPid() {
        XCTAssertEqual(
            SessionRebindCandidatePolicy.excludePidForEndedResurrection(currentPid: 1234),
            1234
        )
    }

    func testEndedResurrectionHasNoExcludeWhenCurrentPidIsMissing() {
        XCTAssertNil(SessionRebindCandidatePolicy.excludePidForEndedResurrection(currentPid: nil))
    }

    func testHookResurrectionRejectsSamePidAfterEnded() {
        XCTAssertFalse(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: 1234,
                evidence: .ordinary
            )
        )
    }

    func testPiSessionStartIsExactRebindEvidence() {
        XCTAssertEqual(
            SessionRebindCandidatePolicy.evidence(
                agentID: .pi,
                lifecycleEvent: "SessionStart"
            ),
            .exactSessionStart
        )
    }

    func testExactSessionStartAllowsSamePidAfterEnded() {
        XCTAssertTrue(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: 1234,
                evidence: .exactSessionStart
            )
        )
    }

    func testPiHeartbeatIsPhaseNeutralRebindEvidence() {
        XCTAssertEqual(
            SessionRebindCandidatePolicy.evidence(
                agentID: .pi,
                lifecycleEvent: "SessionHeartbeat"
            ),
            .sessionHeartbeat
        )
        XCTAssertFalse(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: 1234,
                evidence: .sessionHeartbeat
            )
        )
    }

    func testHookResurrectionAllowsDifferentPidAfterEnded() {
        XCTAssertTrue(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: 5678,
                evidence: .ordinary
            )
        )
    }

    func testHookResurrectionRejectsMissingPidBecauseItCannotProveReattach() {
        XCTAssertFalse(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: nil,
                evidence: .ordinary
            )
        )
    }
}
