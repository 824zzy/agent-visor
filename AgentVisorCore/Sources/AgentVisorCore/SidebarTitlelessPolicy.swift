import Foundation

/// Decides whether a sidebar row hides its title line.
///
/// The rule reads seven fields of a session, so it takes the session. Two call sites once
/// derived those seven values themselves, and a rule change had to be copied into both.
///
/// Row state that the session does not know stays explicit. `isSelected` belongs to the list,
/// and the two call sites define attention differently: the window uses a phase test of its
/// own, and the strip uses `phase.isWaitingForApproval`.
public enum SidebarTitlelessPolicy {
    public static func shouldHide(
        session: SessionState,
        isSelected: Bool,
        needsAttention: Bool
    ) -> Bool {
        if isSelected { return false }
        if needsAttention { return false }

        let hasSessionName = !(session.sessionName ?? "").isEmpty
        let hasFirstUserMessage = !(session.conversationInfo.firstUserMessage ?? "").isEmpty
        if hasSessionName || hasFirstUserMessage || !session.chatItems.isEmpty { return false }

        // A terminal session shows its tty, so the row still has something to say.
        if session.tty != nil { return false }

        // Cursor never reports a tty, so the rule above would hide every Cursor row.
        if session.agentID == .cursor { return false }

        if session.terminalHost == .zed {
            return session.conversationInfo.lastActivityDate == nil
        }

        return true
    }
}
