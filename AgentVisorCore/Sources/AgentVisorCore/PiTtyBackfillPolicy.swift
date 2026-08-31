/// Decides whether Agent Visor should resolve a Pi runtime's controlling TTY
/// from its live process because a hook attached a PID but no TTY.
///
/// The bundled extension resolves its controlling TTY once at load with a
/// bounded probe; under load that probe can time out and report no TTY for the
/// process's lifetime, leaving a resumed Pi session attached with a live PID
/// but `tty` absent. Exact-terminal navigation, terminal-host detection, and
/// terminal origin all require that TTY, so Agent Visor backfills it from the
/// process itself.
///
/// The decision is pure — the actual `ps` lookup is a separate side effect —
/// and bounded so a reported TTY is never overridden and no other provider
/// forks a process for this.
public enum PiTtyBackfillPolicy {
    public static func shouldResolveTTY(
        agentID: AgentID,
        pid: Int?,
        tty: String?
    ) -> Bool {
        guard agentID == .pi, let pid, pid > 0 else { return false }
        return (tty ?? "").isEmpty
    }

    /// Normalize the result of the bounded live `ps` probe. A non-zero exit,
    /// timeout, empty output, or malformed TTY is intentionally indistinguish-
    /// able from no evidence: callers must fail closed rather than reuse a
    /// cached or guessed terminal target.
    public static func tty(
        from output: String?,
        succeeded: Bool
    ) -> String? {
        guard succeeded, let output else { return nil }
        return TTYNormalizer.normalize(output)
    }
}
