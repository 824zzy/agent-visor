import Foundation

/// Whether an answer about a session's liveness still describes that session.
///
/// The sweep asks each agent which of its sessions are dead. That answer costs a
/// question to the machine, which takes time, so the sweep now waits for it away
/// from the threads that serve the rest of the app. During that wait, other work
/// runs: a hook event can arrive, a transcript can change, a row can rebind to a
/// new process.
///
/// So the answer describes the row as it was when the question was asked, not as
/// it is now. Ending a row on a stale answer would show the user a grey dot for a
/// session that just reported work. This rule keeps that from happening.
///
/// A stale answer is not a lost answer. The sweep runs every few seconds, so the
/// next one asks again with the newer facts.
public enum LivenessAnswerFreshnessPolicy {
    /// Does the death answer still apply to this row?
    ///
    /// Three changes make it stale, and each is evidence that the row is not the
    /// row we asked about:
    ///
    /// - a different process, because the row rebound to a live one;
    /// - newer activity, because something reported after we asked;
    /// - a different phase, because stronger evidence already set one.
    public static func stillApplies(asked: SessionState, current: SessionState) -> Bool {
        guard asked.pid == current.pid else { return false }
        guard current.lastActivity <= asked.lastActivity else { return false }
        guard current.phase == asked.phase else { return false }
        return true
    }
}
