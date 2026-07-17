import XCTest
@testable import AgentVisorCore

final class ClaudeCodeSessionMetadataPolicyTests: XCTestCase {
    func testInteractiveCLISessionIsDiscoverable() {
        XCTAssertTrue(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "interactive",
            entrypoint: "cli",
            cwd: "/Users/me/project",
            status: "idle"
        ))
    }

    func testNonInteractiveSessionIsNotDiscoverable() {
        XCTAssertFalse(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "bg",
            entrypoint: "cli",
            cwd: "/Users/me/project",
            status: "idle"
        ))
    }

    func testSDKEntrypointIsNotDiscoverable() {
        XCTAssertFalse(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "interactive",
            entrypoint: "sdk-ts",
            cwd: "/Users/me/project",
            status: "idle"
        ))
    }

    func testObserverSessionCwdIsNotDiscoverable() {
        XCTAssertFalse(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "interactive",
            entrypoint: "cli",
            cwd: "/Users/me/observer-sessions/session",
            status: "idle"
        ))
    }

    func testTerminalMetadataStatusIsNotDiscoverable() {
        for status in ["ended", "exited", "closed", "deactivated", "inactive"] {
            XCTAssertTrue(
                ClaudeCodeSessionMetadataPolicy.isTerminalStatus(status),
                "status \(status) should be recognized as terminal"
            )
            XCTAssertFalse(
                ClaudeCodeSessionMetadataPolicy.shouldDiscover(
                    kind: "interactive",
                    entrypoint: "cli",
                    cwd: "/Users/me/project",
                    status: status
                ),
                "status \(status) should not recreate a visible Claude Code session"
            )
        }
    }

    func testUnknownMetadataStatusRemainsDiscoverable() {
        XCTAssertTrue(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "interactive",
            entrypoint: "cli",
            cwd: "/Users/me/project",
            status: nil
        ))
        XCTAssertTrue(ClaudeCodeSessionMetadataPolicy.shouldDiscover(
            kind: "interactive",
            entrypoint: "cli",
            cwd: "/Users/me/project",
            status: "ready"
        ))
        XCTAssertFalse(ClaudeCodeSessionMetadataPolicy.isTerminalStatus(nil))
        XCTAssertFalse(ClaudeCodeSessionMetadataPolicy.isTerminalStatus("ready"))
    }
}
