import XCTest
@testable import AgentVisorCore

final class ComposerRecoveryGenerationIdentityTests: XCTestCase {
    private func identity(
        pid: Int? = 42,
        token: String? = "start-a",
        tty: String? = "ttys001",
        host: TerminalHost? = .ghostty
    ) -> ComposerRecoveryGenerationIdentity {
        ComposerRecoveryGenerationIdentity(
            pid: pid,
            processStartToken: token,
            tty: tty,
            terminalHost: host,
            agentID: .claudeCode,
            origin: .terminal
        )
    }

    func testSameProcessIdentityDoesNotAdvanceGeneration() {
        XCTAssertFalse(identity().requiresReplacement(comparedTo: identity()))
    }

    func testSamePidWithNewStartTokenAdvancesGeneration() {
        XCTAssertTrue(
            identity(token: "start-a").requiresReplacement(
                comparedTo: identity(token: "start-b")
            )
        )
    }

    func testMissingLiveTokenDoesNotAdvanceOnTransientRediscoveryGap() {
        XCTAssertFalse(
            identity(token: "start-a").requiresReplacement(
                comparedTo: identity(token: nil)
            )
        )
    }

    func testTargetRouteChangeAdvancesGenerationWhenBothRoutesAreKnown() {
        XCTAssertTrue(
            identity(host: .ghostty).requiresReplacement(
                comparedTo: identity(host: .iterm2)
            )
        )
    }

    func testUnknownToKnownHostDoesNotDiscardRecovery() {
        XCTAssertFalse(
            identity(host: .unknown).requiresReplacement(
                comparedTo: identity(host: .ghostty)
            )
        )
    }
}
