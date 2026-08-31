import XCTest
@testable import AgentVisorCore

final class ComposerCancellationRecoveryPolicyTests: XCTestCase {
    private func snapshot(
        text: String = "submitted",
        attachments: [String] = [],
        submittedRevision: Int = 4
    ) -> ComposerCancellationSnapshot {
        ComposerCancellationSnapshot(
            sessionId: "session-a",
            text: text,
            attachmentIDs: attachments,
            pendingEchoID: "echo-a",
            submittedRevision: submittedRevision,
            clearedRevision: submittedRevision + 1
        )
    }

    func testRestoresTextAndAttachmentsOnlyForTheUnchangedPostSubmitEmptyComposer() {
        let submitted = snapshot(attachments: ["image-a"])
        XCTAssertEqual(
            ComposerCancellationRecoveryPolicy.decision(
                snapshot: submitted,
                currentSessionId: "session-a",
                currentText: "",
                currentAttachmentIDs: [],
                currentRevision: 5
            ),
            .restore
        )
    }

    func testImageOnlySubmissionUsesTheSameRestoreGuard() {
        let submitted = snapshot(text: "", attachments: ["image-a"])
        XCTAssertEqual(
            ComposerCancellationRecoveryPolicy.decision(
                snapshot: submitted,
                currentSessionId: "session-a",
                currentText: "",
                currentAttachmentIDs: [],
                currentRevision: 5
            ),
            .restore
        )
    }

    func testNewTextAttachmentSessionOrRevisionPreservesCurrentComposer() {
        let submitted = snapshot(attachments: ["image-a"])
        let cases: [(String, [String], String, Int)] = [
            ("newer", [], "session-a", 6),
            ("", ["newer-image"], "session-a", 6),
            ("", [], "session-b", 5),
            ("", [], "session-a", 6),
        ]
        for (text, attachmentIDs, sessionId, revision) in cases {
            XCTAssertEqual(
                ComposerCancellationRecoveryPolicy.decision(
                    snapshot: submitted,
                    currentSessionId: sessionId,
                    currentText: text,
                    currentAttachmentIDs: attachmentIDs,
                    currentRevision: revision
                ),
                .preserveNewerComposer
            )
        }
    }
}
