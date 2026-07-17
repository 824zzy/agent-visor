import XCTest
@testable import AgentVisorCore

final class CodexThreadOwnershipPolicyTests: XCTestCase {
    func testCodexDesktopThreadIsExternalOwnerEvenWithoutTTY() {
        let result = CodexThreadOwnershipPolicy.drivability(
            tty: nil,
            source: "vscode",
            isAgentVisorOwned: false
        )

        XCTAssertEqual(result, .externalOwner)
    }

    func testAgentVisorOwnedThreadIsDrivableThroughAppServer() {
        let result = CodexThreadOwnershipPolicy.drivability(
            tty: nil,
            source: "vscode",
            isAgentVisorOwned: true
        )

        XCTAssertEqual(result, .agentVisorAppServer)
    }

    func testTerminalThreadIsExternalEvenIfClaimed() {
        let result = CodexThreadOwnershipPolicy.drivability(
            tty: "ttys001",
            source: "cli",
            isAgentVisorOwned: true
        )

        XCTAssertEqual(result, .externalOwner)
    }
}
