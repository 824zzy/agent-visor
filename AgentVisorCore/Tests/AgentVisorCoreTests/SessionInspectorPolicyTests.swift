import XCTest
@testable import AgentVisorCore

final class SessionInspectorPolicyTests: XCTestCase {
    func testReadySessionOpensOriginalBeforeTranscript() {
        let presentation = SessionInspectorPolicy.presentation(
            phase: .ready,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: false
        )

        XCTAssertEqual(presentation.statusTitle, "Ready for you")
        XCTAssertEqual(
            presentation.primaryAction,
            SessionInspectorActionPresentation(
                action: .openOriginal,
                title: "Open in Codex"
            )
        )
        XCTAssertEqual(
            presentation.secondaryAction,
            SessionInspectorActionPresentation(
                action: .inspectTranscript,
                title: "Inspect transcript"
            )
        )
    }

    func testActionableAttentionReviewsRequestBeforeOpeningOriginal() {
        let presentation = SessionInspectorPolicy.presentation(
            phase: .needsAttention,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: true
        )

        XCTAssertEqual(presentation.statusTitle, "Needs attention")
        XCTAssertEqual(
            presentation.primaryAction,
            SessionInspectorActionPresentation(
                action: .inspectTranscript,
                title: "Review request"
            )
        )
        XCTAssertEqual(
            presentation.secondaryAction,
            SessionInspectorActionPresentation(
                action: .openOriginal,
                title: "Open in Codex"
            )
        )
    }

    func testObservedAttentionRoutesBackToOwningApp() {
        let presentation = SessionInspectorPolicy.presentation(
            phase: .needsAttention,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: false
        )

        XCTAssertEqual(presentation.statusTitle, "Needs attention")
        XCTAssertEqual(
            presentation.primaryAction,
            SessionInspectorActionPresentation(
                action: .openOriginal,
                title: "Review in Codex"
            )
        )
        XCTAssertEqual(
            presentation.secondaryAction,
            SessionInspectorActionPresentation(
                action: .inspectTranscript,
                title: "Inspect transcript"
            )
        )
    }

    func testEndedSessionKeepsTranscriptAsTheOnlyAction() {
        let presentation = SessionInspectorPolicy.presentation(
            phase: .ended,
            ownerDisplayName: "iTerm2",
            canOpenOriginal: false,
            canInspectTranscript: true,
            canHandleAttention: false
        )

        XCTAssertEqual(presentation.statusTitle, "Session ended")
        XCTAssertEqual(
            presentation.primaryAction,
            SessionInspectorActionPresentation(
                action: .inspectTranscript,
                title: "Inspect transcript"
            )
        )
        XCTAssertNil(presentation.secondaryAction)
    }

    func testStatusCopyDistinguishesWorkingCompactingAndRecent() {
        let working = SessionInspectorPolicy.presentation(
            phase: .working,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: false
        )
        let compacting = SessionInspectorPolicy.presentation(
            phase: .compacting,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: false
        )
        let recent = SessionInspectorPolicy.presentation(
            phase: .recent,
            ownerDisplayName: "Codex",
            canOpenOriginal: true,
            canInspectTranscript: true,
            canHandleAttention: false
        )

        XCTAssertEqual(working.statusTitle, "Working")
        XCTAssertEqual(compacting.statusTitle, "Compacting context")
        XCTAssertEqual(recent.statusTitle, "Recent session")
    }
}
