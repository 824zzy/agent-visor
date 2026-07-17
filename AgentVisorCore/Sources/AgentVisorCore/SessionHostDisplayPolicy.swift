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
}
