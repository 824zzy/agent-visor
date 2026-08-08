import Foundation

/// Decides whether a discovered row represents saved history or a currently
/// hosted session when no per-session process identifier is available.
///
/// `pid == 0` is normally the persisted-history sentinel. App-owned thread
/// stores are the bounded exception: Codex.app and Zed can prove that a thread
/// is currently hosted even though their worker process is shared or hidden
/// behind ACP and therefore cannot supply a meaningful per-thread PID.
public enum SessionBootstrapLivenessPolicy {
    public static func isHistorical(
        agentID: AgentID,
        pid: Int,
        tty: String?,
        declaredHost: TerminalHost?
    ) -> Bool {
        guard pid == 0 else { return false }
        if declaredHost == .zed { return false }
        if agentID == .codex, tty == nil { return false }
        return true
    }
}
