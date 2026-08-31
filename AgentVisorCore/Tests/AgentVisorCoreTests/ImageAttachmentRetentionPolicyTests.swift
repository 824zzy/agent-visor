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

    func testCanonicalCleanupCannotReleaseAttachmentStillRetainedByRetry() {
        XCTAssertFalse(
            ImageAttachmentRetentionPolicy.mayRelease(
                attachmentID: "image-a",
                event: .canonicalSuccess,
                retainedAttachmentIDs: ["image-a"]
            )
        )
    }

    func testConfirmedCancellationCannotReleaseAttachmentSharedByAnotherDelivery() {
        XCTAssertFalse(
            ImageAttachmentRetentionPolicy.mayRelease(
                attachmentID: "image-shared",
                event: .explicitDismiss,
                retainedAttachmentIDs: ["image-shared"]
            )
        )
        XCTAssertTrue(
            ImageAttachmentRetentionPolicy.mayRelease(
                attachmentID: "image-canceled-only",
                event: .explicitDismiss,
                retainedAttachmentIDs: []
            )
        )
    }

    func testDismissAndRestoredExpiryMayReleaseOnlyUnreferencedAttachment() {
        XCTAssertTrue(
            ImageAttachmentRetentionPolicy.mayRelease(
                attachmentID: "image-a",
                event: .explicitDismiss,
                retainedAttachmentIDs: []
            )
        )
        XCTAssertTrue(
            ImageAttachmentRetentionPolicy.mayRelease(
                attachmentID: "image-b",
                event: .expiredAfterRestore,
                retainedAttachmentIDs: []
            )
        )
    }

    func testRetentionReferenceCapIsExplicitlyBounded() {
        XCTAssertEqual(ImageAttachmentRetentionPolicy.maxRetainedAttachmentReferences, 512)
    }

    func testBatchCleanupReleasesOnlyUnreferencedAttachments() {
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.releasableAttachmentIDs(
                ["image-a", "image-shared", "image-b"],
                event: .canonicalSuccess,
                retainedAttachmentIDs: ["image-shared"]
            ),
            ["image-a", "image-b"]
        )
    }

    func testBatchCleanupPreservesReferencesAcrossGenerationsAndDrafts() {
        XCTAssertEqual(
            ImageAttachmentRetentionPolicy.releasableAttachmentIDs(
                ["old-generation", "draft", "unreferenced"],
                event: .explicitDismiss,
                retainedAttachmentIDs: ["old-generation", "draft"]
            ),
            ["unreferenced"]
        )
    }
}
