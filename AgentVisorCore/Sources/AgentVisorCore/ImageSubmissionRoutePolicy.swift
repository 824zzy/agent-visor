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
        hasTTY: Bool,
        terminalHost: TerminalHost?
    ) -> ImageSubmissionRoute {
        guard canSend else { return .unavailable }

        switch agent {
        case .codex:
            // Codex images travel through its app-server route. A concrete
            // Codex.app host is the only host identity that proves this
            // route; observed/unknown hosts remain read-only.
            return terminalHost == .codexApp ? .appServerLocalImage : .unavailable
        case .claudeCode where hasTTY && supportedTerminalHost(terminalHost):
            return .terminalAttachment
        case .pi where hasTTY && supportedTerminalHost(terminalHost):
            return .terminalPathPrompt
        case .claudeCode, .pi, .auggie, .cursor:
            return .unavailable
        }
    }

    private static func supportedTerminalHost(_ host: TerminalHost?) -> Bool {
        switch host {
        case .ghostty, .iterm2: return true
        case .terminalApp, .claudeDesktop, .codexApp, .vscode, .cursor, .zed, .unknown, .none:
            return false
        }
    }
}
