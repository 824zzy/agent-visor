import XCTest
@testable import AgentVisorCore

final class PiSessionHeartbeatPolicyTests: XCTestCase {
    func testNonHeartbeatEventUsesOrdinaryLifecyclePath() {
        XCTAssertEqual(
            disposition(
                event: "AgentStart",
                hasExistingSession: true,
                existingSessionEnded: false,
                existingPid: 101,
                eventPid: 101
            ),
            .notHeartbeat
        )
    }

    func testAbsentSessionReattachesConservativelyAsIdle() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: false,
                existingSessionEnded: false,
                existingPid: nil,
                eventPid: 202
            ),
            .reattachIdle
        )
    }

    func testHistoricalEndedSessionWithoutPidReattachesAsIdle() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: nil,
                eventPid: 202
            ),
            .reattachIdle
        )
    }

    func testEndedSessionReattachesFromDifferentPid() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: 101,
                eventPid: 202
            ),
            .reattachIdle
        )
    }

    func testEndedSessionDoesNotReattachFromSamePid() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: 202,
                eventPid: 202
            ),
            .ignore
        )
    }

    func testHeartbeatWithoutPidCannotProveLiveAttachment() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: nil,
                eventPid: nil
            ),
            .ignore
        )
    }

    func testHeartbeatPreservesAlreadyLiveSessionState() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: false,
                existingPid: 202,
                eventPid: 202
            ),
            .preserveLiveState
        )
    }

    func testHeartbeatCannotEvictDifferentLiveSessionOwningPid() {
        XCTAssertEqual(
            disposition(
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: nil,
                eventPid: 202,
                hasDifferentLiveSessionWithEventPid: true
            ),
            .ignore
        )
    }

    func testOnlyPiHeartbeatUsesHeartbeatPolicy() {
        XCTAssertEqual(
            PiSessionHeartbeatPolicy.disposition(
                agentID: .claudeCode,
                lifecycleEvent: "SessionHeartbeat",
                hasExistingSession: true,
                existingSessionEnded: true,
                existingPid: nil,
                eventPid: 202,
                hasDifferentLiveSessionWithEventPid: false
            ),
            .notHeartbeat
        )
    }

    private func disposition(
        event: String = "SessionHeartbeat",
        hasExistingSession: Bool,
        existingSessionEnded: Bool,
        existingPid: Int?,
        eventPid: Int?,
        hasDifferentLiveSessionWithEventPid: Bool = false
    ) -> PiSessionHeartbeatPolicy.Disposition {
        PiSessionHeartbeatPolicy.disposition(
            agentID: .pi,
            lifecycleEvent: event,
            hasExistingSession: hasExistingSession,
            existingSessionEnded: existingSessionEnded,
            existingPid: existingPid,
            eventPid: eventPid,
            hasDifferentLiveSessionWithEventPid: hasDifferentLiveSessionWithEventPid
        )
    }
}
