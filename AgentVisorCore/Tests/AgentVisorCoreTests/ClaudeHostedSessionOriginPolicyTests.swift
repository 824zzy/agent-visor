import Foundation
import XCTest
@testable import AgentVisorCore

final class ClaudeHostedSessionOriginPolicyTests: XCTestCase {
    func testClaudeDesktopWithoutTTYIsObservedRatherThanCursorOwned() {
        XCTAssertEqual(
            ClaudeHostedSessionOriginPolicy.origin(
                hasTTY: false,
                terminalHost: .claudeDesktop
            ),
            .observed
        )
    }

    func testCursorWithoutTTYIsCursorOwnedAndTTYSessionIsTerminalOwned() {
        XCTAssertEqual(
            ClaudeHostedSessionOriginPolicy.origin(
                hasTTY: false,
                terminalHost: .cursor
            ),
            .cursorObserved
        )
        XCTAssertEqual(
            ClaudeHostedSessionOriginPolicy.origin(
                hasTTY: true,
                terminalHost: .iterm2
            ),
            .terminal
        )
    }

    func testSessionStoreClassifiesNoTTYOwnershipWithDetectedHost() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(source.contains("ClaudeHostedSessionOriginPolicy.origin("))
        XCTAssertTrue(source.contains("terminalHost: host"))
    }
}
