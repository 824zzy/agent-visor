import Foundation

/// What removing a session row can mean, given what Agent Visor can safely do
/// to the agent's backing data.
public enum SessionDeletability: Equatable, Sendable {
    /// We can delete the agent's transcript file (irreversible). Only ever
    /// returned for a Claude Code session that is NOT live — the row's hover
    /// affordance shows a trash icon and confirms before deleting.
    case deletableTranscript
    /// We must not touch the backing data — only hide the row locally
    /// (reversible). Codex (read-only sqlite + engine-owned rollout),
    /// Cursor/Zed (observed, read-only), and any LIVE Claude Code session
    /// (deleting a live transcript corrupts via an unlinked fd).
    case hideOnly
}

/// Decides, per agent + liveness, whether a session's backing data can be
/// safely deleted or only hidden. Pure / value-in-value-out so both the row
/// view (which icon) and the view model (which action) read the same rule.
///
/// `isLive` is computed App-side (visor-spawned → SpawnedSessionManager
/// ownership; otherwise `kill(pid, 0)`), since process liveness isn't a Core
/// concern — but the safety decision that depends on it is.
public enum SessionDeletabilityPolicy {
    public static func deletability(agentID: AgentID, isLive: Bool) -> SessionDeletability {
        switch agentID {
        case .claudeCode:
            // Transcript is a JSONL we own the path to — deletable, but only
            // when nothing is still writing it.
            return isLive ? .hideOnly : .deletableTranscript
        case .codex, .cursor, .auggie:
            // Read-only / observed agents: never delete their data.
            return .hideOnly
        }
    }
}
