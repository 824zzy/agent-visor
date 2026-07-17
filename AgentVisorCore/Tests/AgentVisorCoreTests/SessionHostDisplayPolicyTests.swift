import XCTest
@testable import AgentVisorCore

final class SessionHostDisplayPolicyTests: XCTestCase {
    func testCodexWithoutHostDisplaysAsCodexApp() {
        XCTAssertEqual(
            SessionHostDisplayPolicy.displayHost(agentID: .codex, terminalHost: nil),
            .codexApp
        )
    }

    func testCodexUnknownHostDisplaysAsCodexApp() {
        XCTAssertEqual(
            SessionHostDisplayPolicy.displayHost(agentID: .codex, terminalHost: .unknown),
            .codexApp
        )
    }

    func testNonCodexWithoutHostRemainsHostless() {
        XCTAssertNil(
            SessionHostDisplayPolicy.displayHost(agentID: .claudeCode, terminalHost: nil)
        )
    }
}
