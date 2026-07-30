import XCTest
@testable import AgentVisorCore

final class ClaudeCodeSessionMetadataPolicyTests: XCTestCase {
    func testBusyMetadataStatusIsWorking() {
        XCTAssertEqual(
            ClaudeCodeSessionMetadataPolicy.activity(for: "busy"),
            .working
        )
        XCTAssertEqual(
            ClaudeCodeSessionMetadataPolicy.activity(for: " BUSY "),
            .working
        )
    }

    func testIdleTerminalAndMissingMetadataHaveDistinctActivity() {
        XCTAssertEqual(
            ClaudeCodeSessionMetadataPolicy.activity(for: "idle"),
            .idle
        )
        XCTAssertEqual(
            ClaudeCodeSessionMetadataPolicy.activity(for: "ended"),
            .terminal
        )
        XCTAssertEqual(
            ClaudeCodeSessionMetadataPolicy.activity(for: nil),
            .unknown
        )
    }

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

    func testClaudeDesktopWithoutTTYUsesTranscriptCompletionFallback() {
        XCTAssertTrue(ClaudeDesktopTranscriptFallbackPolicy.isEligible(
            terminalHost: .claudeDesktop,
            hasTTY: false
        ))
        XCTAssertFalse(ClaudeDesktopTranscriptFallbackPolicy.isEligible(
            terminalHost: .claudeDesktop,
            hasTTY: true
        ))
        XCTAssertFalse(ClaudeDesktopTranscriptFallbackPolicy.isEligible(
            terminalHost: .iterm2,
            hasTTY: false
        ))
    }

    func testUnknownClaudeDesktopMetadataAcceptsTranscriptNewerThanHookEvidence() {
        XCTAssertTrue(ClaudeDesktopTranscriptFallbackPolicy.shouldApply(
            metadataActivity: .unknown,
            transcriptModifiedAt: 200,
            hookObservedAt: 100
        ))
        XCTAssertTrue(ClaudeDesktopTranscriptFallbackPolicy.shouldApply(
            metadataActivity: .unknown,
            transcriptModifiedAt: 200,
            hookObservedAt: nil
        ))
    }

    func testClaudeDesktopFallbackDoesNotOverrideNewerHookOrAuthoritativeMetadata() {
        XCTAssertFalse(ClaudeDesktopTranscriptFallbackPolicy.shouldApply(
            metadataActivity: .unknown,
            transcriptModifiedAt: 99,
            hookObservedAt: 100
        ))

        for activity in [
            ClaudeCodeSessionMetadataActivity.working,
            .idle,
            .terminal,
        ] {
            XCTAssertFalse(ClaudeDesktopTranscriptFallbackPolicy.shouldApply(
                metadataActivity: activity,
                transcriptModifiedAt: 200,
                hookObservedAt: 100
            ))
        }
    }

    func testMissedClaudeDesktopStopRecoversAssistantTranscriptFromReadyToRecent() {
        XCTAssertTrue(ClaudeDesktopTranscriptFallbackPolicy.shouldApply(
            metadataActivity: .unknown,
            transcriptModifiedAt: 200,
            hookObservedAt: 100
        ))
        XCTAssertEqual(
            TranscriptPhaseInferrer.infer(
                turnMarker: .none,
                lastEntryRole: .assistant,
                quiescentSeconds: 10
            ),
            .waitingForInput
        )
        XCTAssertEqual(
            TranscriptPhaseInferrer.infer(
                turnMarker: .none,
                lastEntryRole: .assistant,
                quiescentSeconds: 1_801
            ),
            .idle
        )
    }
}
