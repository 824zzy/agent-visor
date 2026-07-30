import Foundation

public enum ImageSubmissionRoute: Equatable, Sendable {
    case unavailable
    case appServerLocalImage
    case terminalAttachment
    case terminalPathPrompt
}

/// Chooses image semantics separately from ordinary text submission.
/// Runtime sendability and exact-terminal evidence remain caller-owned inputs.
public enum ImageSubmissionRoutePolicy {
    public static func route(
        agent: AgentID,
        canSend: Bool,
        hasTTY: Bool
    ) -> ImageSubmissionRoute {
        guard canSend else { return .unavailable }

        switch agent {
        case .codex:
            return .appServerLocalImage
        case .claudeCode where hasTTY:
            return .terminalAttachment
        case .pi where hasTTY:
            return .terminalPathPrompt
        case .claudeCode, .pi, .auggie, .cursor:
            return .unavailable
        }
    }
}
