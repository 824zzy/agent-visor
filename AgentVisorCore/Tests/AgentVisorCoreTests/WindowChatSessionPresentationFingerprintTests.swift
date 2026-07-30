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

    func testCatalogDisplayNameChangeInvalidatesChatPresentation() {
        XCTAssertNotEqual(
            makeFingerprint(capability: .connected, modelDisplayName: nil),
            makeFingerprint(capability: .connected, modelDisplayName: "GPT-5.6-Sol")
        )
    }

    private func makeFingerprint(
        capability: CodexControlCapability,
        modelDisplayName: String? = "GPT-5.6"
    ) -> WindowChatSessionPresentationFingerprint {
        WindowChatSessionPresentationFingerprint(
            displayTitle: "Thread",
            projectName: "Project",
            phaseTag: "waitingForInput",
            permissionMode: nil,
            modelName: "gpt-5.6",
            modelDisplayName: modelDisplayName,
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
