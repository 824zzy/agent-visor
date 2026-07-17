public enum PendingApprovalCompletionPolicy {
    /// Returns true when an event proves that a pending human decision no
    /// longer blocks the turn. Claude Code has stable tool IDs, so only the
    /// matching completion is authoritative. Observed Codex hooks often omit
    /// identity; after its native UI accepts the decision, PreToolUse (allow)
    /// or UserPromptSubmit (answered question) is the first definitive edge.
    public static func shouldReleaseWaitingState(
        agentID: AgentID,
        event: String,
        incomingToolUseId: String?,
        incomingToolName: String?,
        pendingToolUseId: String,
        pendingToolName: String
    ) -> Bool {
        if matchesPendingTool(
            event: event,
            completedToolUseId: incomingToolUseId,
            completedToolName: incomingToolName,
            pendingToolUseId: pendingToolUseId,
            pendingToolName: pendingToolName
        ) {
            return true
        }
        guard agentID == .codex else { return false }
        if event == "UserPromptSubmit" {
            return true
        }
        guard event == "PreToolUse" else { return false }
        if let incomingToolUseId,
           !incomingToolUseId.isEmpty,
           !pendingToolUseId.isEmpty {
            return incomingToolUseId == pendingToolUseId
        }
        if let incomingName = PendingActionPresentation.contextualToolName(incomingToolName),
           let pendingName = PendingActionPresentation.contextualToolName(pendingToolName) {
            return incomingName.lowercased() == pendingName.lowercased()
        }
        return true
    }

    public static func matchesPendingTool(
        event: String,
        completedToolUseId: String?,
        completedToolName: String?,
        pendingToolUseId: String,
        pendingToolName: String
    ) -> Bool {
        guard event == "PostToolUse" || event == "PostToolUseFailure" else {
            return false
        }

        if let completedToolUseId,
           !completedToolUseId.isEmpty,
           !pendingToolUseId.isEmpty {
            return completedToolUseId == pendingToolUseId
        }
        return completedToolName == pendingToolName
    }
}
