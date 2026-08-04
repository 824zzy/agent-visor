import XCTest
@testable import AgentVisorCore

final class PiTtyBackfillPolicyTests: XCTestCase {
    func testPiRuntimeWithLivePidAndMissingTtyResolves() {
        XCTAssertTrue(
            PiTtyBackfillPolicy.shouldResolveTTY(agentID: .pi, pid: 11882, tty: nil)
        )
    }

    func testPiRuntimeWithEmptyTtyResolves() {
        XCTAssertTrue(
            PiTtyBackfillPolicy.shouldResolveTTY(agentID: .pi, pid: 11882, tty: "")
        )
    }

    func testReportedTtyIsNeverOverridden() {
        XCTAssertFalse(
            PiTtyBackfillPolicy.shouldResolveTTY(agentID: .pi, pid: 11882, tty: "ttys001")
        )
    }

    func testMissingPidDoesNotResolve() {
        XCTAssertFalse(
            PiTtyBackfillPolicy.shouldResolveTTY(agentID: .pi, pid: nil, tty: nil)
        )
    }

    func testNonPositivePidDoesNotResolve() {
        XCTAssertFalse(
            PiTtyBackfillPolicy.shouldResolveTTY(agentID: .pi, pid: 0, tty: nil)
        )
    }

    func testNonPiProvidersNeverResolve() {
        for provider in [AgentID.codex, .claudeCode, .cursor] {
            XCTAssertFalse(
                PiTtyBackfillPolicy.shouldResolveTTY(agentID: provider, pid: 11882, tty: nil),
                "\(provider) must not fork a process to resolve a TTY."
            )
        }
    }
}
