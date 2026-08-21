import Foundation

public enum SessionHostDisplayPolicy {
    public static func displayHost(agentID: AgentID, terminalHost: TerminalHost?) -> TerminalHost? {
        if agentID == .codex {
            switch terminalHost {
            case .none, .unknown:
                return .codexApp
            default:
                return terminalHost
            }
        }
        return terminalHost
    }

    public static func metadata(agentID: AgentID, terminalHost: TerminalHost?) -> HostMetadata {
        HostMetadata.metadata(for: displayHost(agentID: agentID, terminalHost: terminalHost) ?? .unknown)
    }

    /// The host to show for a session.
    ///
    /// Callers that hold a session use this form, so the rule can read another field later
    /// without changing every call site. `SourceChip` keeps the field form: it is a view that
    /// takes an agent and a host as parameters and never sees a session.
    public static func displayHost(session: SessionState) -> TerminalHost? {
        displayHost(agentID: session.agentID, terminalHost: session.terminalHost)
    }
}
