import XCTest
@testable import AgentVisorCore

final class CursorHostedSessionLivenessPolicyTests: XCTestCase {
    func testDropsCursorClaudeProcessWithoutTranscript() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: false,
            entrypoint: "claude-vscode",
            processAlive: true,
            isTerminalStatus: false,
            transcriptModifiedAt: nil,
            now: 10_000,
            observedWindowSeconds: 900
        )

        XCTAssertEqual(result, .drop)
    }

    func testKeepsCursorClaudeProcessWithTranscriptInsideObservedWindow() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: false,
            entrypoint: "claude-vscode",
            processAlive: true,
            isTerminalStatus: false,
            transcriptModifiedAt: 9_900,
            now: 10_000,
            observedWindowSeconds: 900
        )

        XCTAssertEqual(result, .live)
    }

    func testDropsCursorClaudeProcessWithStaleTranscript() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: false,
            entrypoint: "claude-vscode",
            processAlive: true,
            isTerminalStatus: false,
            transcriptModifiedAt: 8_000,
            now: 10_000,
            observedWindowSeconds: 900
        )

        XCTAssertEqual(result, .drop)
    }

    func testTerminalClaudeProcessKeepsCurrentPidBackedBehaviorWithoutTranscript() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: true,
            entrypoint: "cli",
            processAlive: true,
            isTerminalStatus: false,
            transcriptModifiedAt: nil,
            now: 10_000,
            observedWindowSeconds: 900
        )

        XCTAssertEqual(result, .live)
    }

    func testPendingUserActionKeepsObservedSessionEvenWithoutTranscript() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: false,
            entrypoint: "claude-vscode",
            processAlive: true,
            isTerminalStatus: false,
            transcriptModifiedAt: nil,
            now: 10_000,
            observedWindowSeconds: 900,
            hasPendingUserAction: true
        )

        XCTAssertEqual(result, .live)
    }

    func testTerminalMetadataStatusDropsSession() {
        let result = CursorHostedSessionLivenessPolicy.classify(
            hasTTY: false,
            entrypoint: "claude-vscode",
            processAlive: true,
            isTerminalStatus: true,
            transcriptModifiedAt: 9_990,
            now: 10_000,
            observedWindowSeconds: 900
        )

        XCTAssertEqual(result, .drop)
    }
}
