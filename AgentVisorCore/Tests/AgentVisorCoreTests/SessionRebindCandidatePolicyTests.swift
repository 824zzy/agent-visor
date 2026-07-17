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
                eventPid: 1234
            )
        )
    }

    func testHookResurrectionAllowsDifferentPidAfterEnded() {
        XCTAssertTrue(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: 5678
            )
        )
    }

    func testHookResurrectionRejectsMissingPidBecauseItCannotProveReattach() {
        XCTAssertFalse(
            SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
                currentPid: 1234,
                eventPid: nil
            )
        )
    }
}
