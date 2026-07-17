import Foundation

public enum SidebarTitlelessPolicy {
    public static func shouldHide(
        isSelected: Bool,
        needsAttention: Bool,
        agentID: AgentID,
        terminalHost: TerminalHost?,
        hasTTY: Bool,
        hasSessionName: Bool,
        hasFirstUserMessage: Bool,
        hasChatItems: Bool,
        hasLastActivityDate: Bool
    ) -> Bool {
        if isSelected { return false }
        if needsAttention { return false }
        if hasSessionName || hasFirstUserMessage || hasChatItems { return false }

        if hasTTY { return false }

        if agentID == .cursor && !hasTTY { return false }

        if terminalHost == .zed {
            return !hasLastActivityDate
        }

        return true
    }
}
