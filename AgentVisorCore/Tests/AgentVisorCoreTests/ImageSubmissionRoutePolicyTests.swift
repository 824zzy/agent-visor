import XCTest
@testable import AgentVisorCore

final class ImageSubmissionRoutePolicyTests: XCTestCase {
    func testLivePiTerminalUsesNativeEquivalentPathPrompt() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: true,
                hasTTY: true
            ),
            .terminalPathPrompt
        )
    }

    func testPiWithoutAnExactTTYCannotAcceptImages() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: true,
                hasTTY: false
            ),
            .unavailable
        )
    }

    func testReadOnlySessionCannotAcceptImagesEvenWhenItHasATTY() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: false,
                hasTTY: true
            ),
            .unavailable
        )
    }

    func testClaudeTerminalKeepsAttachmentAwarePasteRoute() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .claudeCode,
                canSend: true,
                hasTTY: true
            ),
            .terminalAttachment
        )
    }

    func testControllableCodexUsesLocalImagePayloadsWithoutATTY() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .codex,
                canSend: true,
                hasTTY: false
            ),
            .appServerLocalImage
        )
    }

    func testUnsupportedProvidersDoNotAdvertiseImageSubmission() {
        for agent in [AgentID.auggie, .cursor] {
            XCTAssertEqual(
                ImageSubmissionRoutePolicy.route(
                    agent: agent,
                    canSend: true,
                    hasTTY: true
                ),
                .unavailable
            )
        }
    }
}
