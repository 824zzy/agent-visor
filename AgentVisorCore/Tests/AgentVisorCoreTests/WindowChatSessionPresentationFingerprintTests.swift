import XCTest
@testable import AgentVisorCore

final class WindowChatSessionPresentationFingerprintTests: XCTestCase {
    func testConnectingObservedCodexInvalidatesChatPresentation() {
        let observed = makeFingerprint(capability: .observed)
        let connected = makeFingerprint(capability: .connected)

        XCTAssertNotEqual(observed, connected)
    }

    func testUnchangedPresentationMetadataRemainsStable() {
        XCTAssertEqual(
            makeFingerprint(capability: .connected),
            makeFingerprint(capability: .connected)
        )
    }

    private func makeFingerprint(
        capability: CodexControlCapability
    ) -> WindowChatSessionPresentationFingerprint {
        WindowChatSessionPresentationFingerprint(
            displayTitle: "Thread",
            projectName: "Project",
            phaseTag: "waitingForInput",
            permissionMode: nil,
            modelName: "gpt-5.6",
            contextWindowTokens: 200_000,
            contextTokenBucket: 12,
            effortLevel: "high",
            cwd: "/Users/test/Project",
            agentID: .codex,
            originTag: "observed",
            codexControlCapability: capability,
            tty: nil,
            terminalHost: .codexApp
        )
    }
}
