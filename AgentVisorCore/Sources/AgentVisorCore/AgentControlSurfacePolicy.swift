import Foundation

public enum AgentControlSessionOwnership: Equatable, Sendable {
    case agentVisorAppServer
    case ownerApp(host: TerminalHost?)
    case terminal(host: TerminalHost?)
    case opaqueHost(host: TerminalHost?)
}

public enum AgentControlLifecycle: Equatable, Sendable {
    case live
    case waitingForApproval
    case ended
}

public enum AgentControlPrimaryAction: Equatable, Sendable {
    case none
    case openOwnerApp
    case approveInOwnerApp
    case focusHost
}

public struct AgentControlSurfaceDecision: Equatable, Sendable {
    public let allowsComposer: Bool
    public let primaryAction: AgentControlPrimaryAction
    public let primaryActionTitle: String?
    public let headline: String
    public let detail: String

    public init(
        allowsComposer: Bool,
        primaryAction: AgentControlPrimaryAction,
        primaryActionTitle: String?,
        headline: String,
        detail: String
    ) {
        self.allowsComposer = allowsComposer
        self.primaryAction = primaryAction
        self.primaryActionTitle = primaryActionTitle
        self.headline = headline
        self.detail = detail
    }
}

public enum AgentControlSurfacePolicy {
    public static func decision(
        agentID: AgentID,
        ownership: AgentControlSessionOwnership,
        lifecycle: AgentControlLifecycle,
        codexCapability: CodexControlCapability? = nil
    ) -> AgentControlSurfaceDecision {
        if lifecycle == .ended {
            let agentName = displayName(for: agentID)
            return AgentControlSurfaceDecision(
                allowsComposer: false,
                primaryAction: .none,
                primaryActionTitle: nil,
                headline: "\(agentName) session has ended",
                detail: "Chat history is preserved. Re-attach by running the CLI in this project's directory."
            )
        }

        if agentID == .codex,
           codexCapability == .connected || codexCapability == .managed {
            return AgentControlSurfaceDecision(
                allowsComposer: true,
                primaryAction: .none,
                primaryActionTitle: nil,
                headline: "",
                detail: ""
            )
        }

        switch ownership {
        case .agentVisorAppServer:
            return AgentControlSurfaceDecision(
                allowsComposer: true,
                primaryAction: .none,
                primaryActionTitle: nil,
                headline: "",
                detail: ""
            )
        case .ownerApp(let host):
            let appName = ownerAppName(agentID: agentID, host: host)
            let actionTitle = lifecycle == .waitingForApproval ? approveTitle(for: agentID) : openTitle(for: agentID)
            return AgentControlSurfaceDecision(
                allowsComposer: false,
                primaryAction: lifecycle == .waitingForApproval ? .approveInOwnerApp : .openOwnerApp,
                primaryActionTitle: actionTitle,
                headline: lifecycle == .waitingForApproval ? "\(appName) is waiting for approval" : "\(appName) is the primary chat",
                detail: lifecycle == .waitingForApproval
                    ? "Approve or deny it in \(appName); Agent Visor mirrors the result here."
                    : "Agent Visor mirrors this session. Open \(appName) to continue the chat."
            )
        case .terminal(let host), .opaqueHost(let host):
            let hostName = host.map { HostMetadata.metadata(for: $0).displayName } ?? "Host"
            return AgentControlSurfaceDecision(
                allowsComposer: false,
                primaryAction: .focusHost,
                primaryActionTitle: "Focus \(hostName)",
                headline: "\(hostName) is the primary chat",
                detail: "Agent Visor mirrors this session. Continue the chat in \(hostName)."
            )
        }
    }

    private static func displayName(for agentID: AgentID) -> String {
        switch agentID {
        case .claudeCode: return "Claude Code"
        case .auggie: return "Auggie"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    private static func ownerAppName(agentID: AgentID, host: TerminalHost?) -> String {
        if agentID == .codex, host == .codexApp {
            return "Codex Desktop"
        }
        if let host {
            return HostMetadata.metadata(for: host).displayName
        }
        return "\(displayName(for: agentID)) app"
    }

    private static func openTitle(for agentID: AgentID) -> String {
        switch agentID {
        case .codex:
            return "Focus Codex"
        default:
            return "Open"
        }
    }

    private static func approveTitle(for agentID: AgentID) -> String {
        switch agentID {
        case .codex:
            return "Approve in Codex"
        default:
            return "Approve"
        }
    }
}
