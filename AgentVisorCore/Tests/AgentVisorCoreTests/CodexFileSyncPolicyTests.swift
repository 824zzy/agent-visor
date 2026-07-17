import XCTest
@testable import AgentVisorCore

final class CodexFileSyncPolicyTests: XCTestCase {
    func testObservedUnrenderedCodexSessionsUseMetadataOnlySync() {
        let mode = CodexFileSyncPolicy.mode(
            isAgentVisorOwned: false,
            hasRenderedChatItems: false
        )

        XCTAssertEqual(mode, .metadataOnly)
    }

    func testAgentVisorOwnedCodexSessionsUseFullReplaySync() {
        let mode = CodexFileSyncPolicy.mode(
            isAgentVisorOwned: true,
            hasRenderedChatItems: false
        )

        XCTAssertEqual(mode, .fullReplay)
    }

    func testRenderedObservedCodexSessionsUseFullReplaySync() {
        let mode = CodexFileSyncPolicy.mode(
            isAgentVisorOwned: false,
            hasRenderedChatItems: true
        )

        XCTAssertEqual(mode, .fullReplay)
    }
}
