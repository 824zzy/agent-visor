import XCTest
@testable import AgentVisorCore

final class PendingApprovalCompletionPolicyTests: XCTestCase {
    func testObservedCodexPreToolUseClearsMetadataPoorApproval() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "PreToolUse",
            incomingToolUseId: nil,
            incomingToolName: nil,
            pendingToolUseId: "",
            pendingToolName: "unknown"
        ))
    }

    func testMatchingClaudeCompletionStillClearsApproval() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .claudeCode,
            event: "PostToolUse",
            incomingToolUseId: "tool-1",
            incomingToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
    }

    func testObservedCodexUserPromptClearsAnsweredQuestion() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "UserPromptSubmit",
            incomingToolUseId: nil,
            incomingToolName: nil,
            pendingToolUseId: "",
            pendingToolName: "Needs your input"
        ))
    }

    func testCodexParallelToolWithDifferentKnownIdPreservesApproval() {
        XCTAssertFalse(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "PreToolUse",
            incomingToolUseId: "tool-2",
            incomingToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
    }

    func testCodexParallelToolWithDifferentKnownNamePreservesApproval() {
        XCTAssertFalse(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "PreToolUse",
            incomingToolUseId: nil,
            incomingToolName: "ApplyPatch",
            pendingToolUseId: "",
            pendingToolName: "Bash"
        ))
    }

    func testCodexPreToolUseWithMatchingKnownNameClearsApproval() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "PreToolUse",
            incomingToolUseId: nil,
            incomingToolName: "Bash",
            pendingToolUseId: "",
            pendingToolName: "bash"
        ))
    }

    func testClaudePreToolUsePreservesApprovalEvenWhenIdMatches() {
        XCTAssertFalse(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .claudeCode,
            event: "PreToolUse",
            incomingToolUseId: "tool-1",
            incomingToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
    }

    func testCodexUnidentifiedPostToolUseDoesNotClearApproval() {
        XCTAssertFalse(PendingApprovalCompletionPolicy.shouldReleaseWaitingState(
            agentID: .codex,
            event: "PostToolUse",
            incomingToolUseId: nil,
            incomingToolName: nil,
            pendingToolUseId: "",
            pendingToolName: "unknown"
        ))
    }

    func testFailedCompletionResolvesTheMatchingPendingTool() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.matchesPendingTool(
            event: "PostToolUseFailure",
            completedToolUseId: "tool-1",
            completedToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
    }

    func testParallelSiblingAndNonCompletionEventsDoNotResolvePendingTool() {
        XCTAssertFalse(PendingApprovalCompletionPolicy.matchesPendingTool(
            event: "PostToolUse",
            completedToolUseId: "tool-2",
            completedToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
        XCTAssertFalse(PendingApprovalCompletionPolicy.matchesPendingTool(
            event: "PreToolUse",
            completedToolUseId: "tool-1",
            completedToolName: "Bash",
            pendingToolUseId: "tool-1",
            pendingToolName: "Bash"
        ))
    }

    func testToolNameFallbackOnlyAppliesWhenIdsAreUnavailable() {
        XCTAssertTrue(PendingApprovalCompletionPolicy.matchesPendingTool(
            event: "PostToolUse",
            completedToolUseId: nil,
            completedToolName: "Bash",
            pendingToolUseId: "",
            pendingToolName: "Bash"
        ))
    }
}
