import XCTest
@testable import AgentVisorCore

final class ImageSubmissionRoutePolicyTests: XCTestCase {
    func testLivePiTerminalUsesNativeEquivalentPathPrompt() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: true,
                hasTTY: true,
                terminalHost: .ghostty
            ),
            .terminalPathPrompt
        )
    }

    func testPiWithoutAnExactTTYCannotAcceptImages() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: true,
                hasTTY: false,
                terminalHost: .ghostty
            ),
            .unavailable
        )
    }

    func testReadOnlySessionCannotAcceptImagesEvenWhenItHasATTY() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .pi,
                canSend: false,
                hasTTY: true,
                terminalHost: .ghostty
            ),
            .unavailable
        )
    }

    func testClaudeTerminalKeepsAttachmentAwarePasteRoute() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .claudeCode,
                canSend: true,
                hasTTY: true,
                terminalHost: .iterm2
            ),
            .terminalAttachment
        )
    }

    func testControllableCodexUsesLocalImagePayloadsWithoutATTY() {
        XCTAssertEqual(
            ImageSubmissionRoutePolicy.route(
                agent: .codex,
                canSend: true,
                hasTTY: false,
                terminalHost: .codexApp
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
                    hasTTY: true,
                    terminalHost: .ghostty
                ),
                .unavailable
            )
        }
    }

    func testTerminalAppNeverAdvertisesImageDelivery() {
        for agent in [AgentID.claudeCode, .pi] {
            XCTAssertEqual(
                ImageSubmissionRoutePolicy.route(
                    agent: agent,
                    canSend: true,
                    hasTTY: true,
                    terminalHost: .terminalApp
                ),
                .unavailable
            )
        }
    }

    func testUnknownOrMissingHostFailsClosedForTerminalImages() {
        for host: TerminalHost? in [nil, .unknown, .zed] {
            XCTAssertEqual(
                ImageSubmissionRoutePolicy.route(
                    agent: .claudeCode,
                    canSend: true,
                    hasTTY: true,
                    terminalHost: host
                ),
                .unavailable
            )
        }
    }
}
