import Foundation

/// Liveness for a session whose agent runs inside Zed.
///
/// This is a host rule, not an agent rule, and it must be asked before the
/// agent's own rule. Zed pools one ACP child process across every thread, so
/// a live pid says nothing about one thread: closing a claude-acp or
/// codex-acp thread leaves the pooled process running. The per-agent rules
/// below it key on Codex.app's active GUI set or on a pooled pid, so they
/// would keep a closed Zed thread forever.
///
/// Two signals decide it. Zed not running is definitive: every thread it
/// hosted is gone. While Zed runs, the only remaining signal is transcript
/// idleness, measured against the observed-agent window (42h by default).
/// A short window is wrong here: an idle-but-open thread must stay visible,
/// and an earlier 30s window made an open thread vanish as soon as the user
/// stopped typing. A real thread close is normally caught by the agent's own
/// end-of-session event; this rule is the fallback for a thread that went
/// away without one.
public enum ZedHostedSessionLivenessPolicy {
    /// - Parameters:
    ///   - zedRunning: Zed is running, on any release channel.
    ///   - idleSeconds: seconds since the session's last activity.
    ///   - idleWindow: the observed-agent window.
    public static func isDead(
        zedRunning: Bool,
        idleSeconds: TimeInterval,
        idleWindow: TimeInterval
    ) -> Bool {
        guard zedRunning else { return true }
        return idleSeconds > idleWindow
    }
}
