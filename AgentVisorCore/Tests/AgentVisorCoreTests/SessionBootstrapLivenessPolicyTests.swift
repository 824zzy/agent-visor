import XCTest
@testable import AgentVisorCore

final class SessionBootstrapLivenessPolicyTests: XCTestCase {
    func testSourceConfirmedZedThreadIsLiveWithoutAPerSessionPID() {
        XCTAssertFalse(
            SessionBootstrapLivenessPolicy.isHistorical(
                agentID: .pi,
                pid: 0,
                tty: nil,
                declaredHost: .zed
            )
        )
    }

    func testPersistedPiTranscriptWithoutADeclaredLiveHostIsHistorical() {
        XCTAssertTrue(
            SessionBootstrapLivenessPolicy.isHistorical(
                agentID: .pi,
                pid: 0,
                tty: nil,
                declaredHost: nil
            )
        )
    }

    func testCodexObservedAppSentinelRemainsLive() {
        XCTAssertFalse(
            SessionBootstrapLivenessPolicy.isHistorical(
                agentID: .codex,
                pid: 0,
                tty: nil,
                declaredHost: nil
            )
        )
    }
}
