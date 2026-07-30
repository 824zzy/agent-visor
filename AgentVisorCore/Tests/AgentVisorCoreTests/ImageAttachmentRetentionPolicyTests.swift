import XCTest
@testable import AgentVisorCore

final class ImageAttachmentRetentionPolicyTests: XCTestCase {
    func testPiPathPromptSurvivesForOneDay() {
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.cleanupDelay(for: .terminalPathPrompt),
            24 * 60 * 60
        )
    }

    func testExistingClaudeAndCodexRoutesStayShortLived() {
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.cleanupDelay(for: .terminalAttachment),
            60
        )
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.cleanupDelay(for: .appServerLocalImage),
            60
        )
    }

    func testUnavailableRouteDoesNotScheduleAttachmentCleanup() {
        XCTAssertNil(
            ImageAttachmentRetentionPolicy.cleanupDelay(for: .unavailable)
        )
    }

    func testStartupSweepRespectsTheLongestSubmissionLifetime() {
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.staleFileAge,
            24 * 60 * 60
        )
    }
}
