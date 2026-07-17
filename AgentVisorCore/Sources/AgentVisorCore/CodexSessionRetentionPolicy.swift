import Foundation

/// Retention policy for Codex sessions already present in Agent Visor's store.
///
/// Discovery decides which Codex GUI threads should be added from sqlite.
/// Pruning needs a slightly more tolerant rule: keep recent GUI rows even if
/// the sqlite active-set query misses once, then let the observed window cap
/// remove them after they age out.
///
/// Explicit archive relocation always wins. The weaker sqlite `archived` flag
/// does not: Codex can set it on background-research GUI threads that are still
/// writing, so those remain eligible while the active selector confirms them.
public enum CodexSessionRetentionPolicy {
    public static func shouldKeep(
        sessionId: String,
        tty: String?,
        pid: Int?,
        codexAppPid: Int?,
        isNonAppPidAlive: Bool,
        activeGUIThreadIds: Set<String>,
        lastActivity: Date,
        now: Date,
        observedWindowSeconds: TimeInterval,
        isKnownArchived: Bool = false,
        isExplicitlyArchived: Bool = false
    ) -> Bool {
        if isExplicitlyArchived {
            return false
        }

        // Archived ⇒ drop, UNLESS the thread is still in the active set: a
        // running-archived background thread (fresh rollout) the selector just
        // surfaced. Keeping it here avoids pruning what discovery added.
        if isKnownArchived && !activeGUIThreadIds.contains(sessionId) {
            return false
        }

        if tty == nil {
            if activeGUIThreadIds.contains(sessionId) {
                return true
            }
            return now.timeIntervalSince(lastActivity) <= observedWindowSeconds
        }

        guard let pid, pid != 0, pid != codexAppPid else {
            return false
        }
        return isNonAppPidAlive
    }
}
