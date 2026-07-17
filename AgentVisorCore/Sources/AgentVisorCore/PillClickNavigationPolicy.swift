import Foundation

public enum PillClickModifierIntent: Equatable, Sendable {
    case standard
    case forceAgentVisor
}

public enum PillClickNavigationAction: Equatable, Sendable {
    case openAgentVisor
    case openOriginal
}

public struct PillClickMenuModel: Equatable, Sendable {
    public let openAgentVisorTitle: String
    public let openOriginalTitle: String
    public let canOpenOriginal: Bool

    public static func session(
        agentID: AgentID,
        ownership: AgentControlSessionOwnership
    ) -> PillClickMenuModel {
        return PillClickMenuModel(
            openAgentVisorTitle: "Open in Agent Visor",
            openOriginalTitle: originalTitle(agentID: agentID, ownership: ownership),
            canOpenOriginal: ownership != .agentVisorAppServer
        )
    }

    private static func originalTitle(
        agentID: AgentID,
        ownership: AgentControlSessionOwnership
    ) -> String {
        switch ownership {
        case .ownerApp(let host):
            if agentID == .codex, host == .codexApp {
                return "Focus Codex"
            }
            if let host {
                return "Open \(HostMetadata.metadata(for: host).displayName)"
            }
            return "Open original app"
        case .terminal(let host), .opaqueHost(let host):
            if let host {
                return "Focus \(HostMetadata.metadata(for: host).displayName)"
            }
            return "Open original app"
        case .agentVisorAppServer:
            return "Open original app"
        }
    }
}

public struct PillClickOverflowMenuModel: Equatable, Sendable {
    public let openAgentVisorTitle: String
    public let settingsTitle: String

    public static func menu() -> PillClickOverflowMenuModel {
        PillClickOverflowMenuModel(
            openAgentVisorTitle: "Open Agent Visor",
            settingsTitle: "Pill Settings..."
        )
    }
}

public enum PillClickNavigationPolicy {
    public static func action(
        ownership: AgentControlSessionOwnership,
        modifierIntent: PillClickModifierIntent = .standard,
        agentVisorDetailAvailable: Bool = true
    ) -> PillClickNavigationAction {
        if modifierIntent == .forceAgentVisor {
            return agentVisorDetailAvailable ? .openAgentVisor : .openOriginal
        }

        switch ownership {
        case .agentVisorAppServer:
            return .openAgentVisor
        case .terminal, .ownerApp, .opaqueHost:
            return .openOriginal
        }
    }
}
