import XCTest
@testable import AgentVisorCore

final class ComposerCancellationClearProgressTests: XCTestCase {
    private func state(
        sessionId: String = "session-a",
        submissionId: String = "submission-a",
        revision: Int = 8,
        textIsEmpty: Bool = true,
        attachments: [String] = []
    ) -> ComposerCancellationClearState {
        ComposerCancellationClearState(
            sessionId: sessionId,
            submissionId: submissionId,
            clearedRevision: revision,
            textIsEmpty: textIsEmpty,
            attachmentIDs: attachments
        )
    }

    func testMutationBeforeNextChunkAbortsBeforeDestructiveWork() {
        var progress = ComposerCancellationClearProgress(expected: state())
        XCTAssertEqual(progress.beginChunk(current: state()), .proceed)
        XCTAssertEqual(progress.finishChunk(succeeded: true), .proceed)
        XCTAssertEqual(progress.beginChunk(current: state(revision: 9)), .aborted)
        XCTAssertTrue(progress.isAborted)
        XCTAssertEqual(progress.completedChunks, 1)
    }

    func testFailedChunkAbortsAndLaterChunksCannotProceed() {
        var progress = ComposerCancellationClearProgress(expected: state())
        XCTAssertEqual(progress.beginChunk(current: state()), .proceed)
        XCTAssertEqual(progress.finishChunk(succeeded: false), .aborted)
        XCTAssertEqual(progress.beginChunk(current: state()), .aborted)
        XCTAssertEqual(progress.completedChunks, 0)
    }

    func testSessionAttachmentAndSubmissionIdentityAreAllGuarded() {
        var progress = ComposerCancellationClearProgress(expected: state(attachments: ["image-a"]))
        XCTAssertEqual(progress.beginChunk(current: state(attachments: ["image-b"])), .aborted)
        XCTAssertEqual(progress.beginChunk(current: state(submissionId: "submission-b", attachments: ["image-a"])), .aborted)
    }
}
