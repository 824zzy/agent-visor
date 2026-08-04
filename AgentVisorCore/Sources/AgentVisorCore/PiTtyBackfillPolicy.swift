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
}
