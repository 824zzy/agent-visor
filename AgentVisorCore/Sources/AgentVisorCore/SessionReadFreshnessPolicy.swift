import Foundation

/// Whether a delayed answer still describes the session that was asked about.
///
/// Some answers require a question to the machine: read a transcript, inspect a
/// database, or ask whether a process is alive. The store waits for those answers
/// away from the threads that serve the rest of the app. During that wait, a hook
/// event can arrive, a transcript can change, or a row can rebind to a new process.
///
/// So the answer describes the row as it was when the question was asked, not as
/// it is now. Acting on a stale answer could grey out a live session or let old
/// transcript evidence replace a newer phase. This rule prevents both.
///
/// A stale answer is not lost. The next hook, file event, scan, or sweep asks again
/// with the newer facts.
public enum SessionReadFreshnessPolicy {
    /// Does the answer still apply to this row?
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
