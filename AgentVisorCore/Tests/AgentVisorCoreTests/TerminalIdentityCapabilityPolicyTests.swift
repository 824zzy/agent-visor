import XCTest
@testable import AgentVisorCore

final class TerminalIdentityCapabilityPolicyTests: XCTestCase {
    private let firstKey = TerminalIdentityCapabilityKey(
        sessionID: "session-a",
        generationID: "generation-a",
        pid: 42,
        processStartToken: "start-a",
        tty: "/dev/ttys001",
        terminalHost: .ghostty
    )

    func testLoadingIsFailClosedAndAccessible() {
        let state = TerminalIdentityCapability.loading(for: firstKey)

        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.isVerified)
        XCTAssertEqual(
            state.accessibilityLabel,
            "Stopping is unavailable while the terminal target is being verified."
        )
    }

    func testVerifiedStateRequiresTheExactIdentityKey() {
        let state = TerminalIdentityCapability.loading(for: firstKey)
        let replacementKey = TerminalIdentityCapabilityKey(
            sessionID: firstKey.sessionID,
            generationID: firstKey.generationID,
            pid: firstKey.pid,
            processStartToken: "start-b",
            tty: firstKey.tty,
            terminalHost: firstKey.terminalHost
        )

        XCTAssertNil(state.applying(isVerified: true, for: replacementKey))
        XCTAssertEqual(
            state.applying(isVerified: true, for: firstKey),
            TerminalIdentityCapability.resolved(for: firstKey, isVerified: true)
        )
    }

    func testSessionOrGenerationChangeRejectsStaleCompletion() {
        let state = TerminalIdentityCapability.loading(for: firstKey)
        let newerKey = TerminalIdentityCapabilityKey(
            sessionID: "session-b",
            generationID: "generation-b",
            pid: firstKey.pid,
            processStartToken: firstKey.processStartToken,
            tty: firstKey.tty,
            terminalHost: firstKey.terminalHost
        )

        XCTAssertNil(state.applying(isVerified: true, for: newerKey))
    }

    func testUnverifiedResultRemainsFailClosedWithReason() {
        let state = TerminalIdentityCapability.resolved(
            for: firstKey,
            isVerified: false
        )

        XCTAssertFalse(state.isVerified)
        XCTAssertNotNil(state.reason)
        XCTAssertTrue(state.accessibilityLabel.contains("could not be verified"))
    }

    func testKeyNormalizesTTYSoEquivalentDiscoveryDoesNotCreateAFalseChange() {
        let normalized = TerminalIdentityCapabilityKey(
            sessionID: firstKey.sessionID,
            generationID: firstKey.generationID,
            pid: firstKey.pid,
            processStartToken: firstKey.processStartToken,
            tty: "ttys001",
            terminalHost: firstKey.terminalHost
        )

        XCTAssertEqual(normalized, firstKey)
    }
}
