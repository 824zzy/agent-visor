import Foundation

public struct PermissionModeSurfaceDecision: Equatable, Sendable {
    public let displayMode: String?
    public let canCycle: Bool
    public let shouldProbe: Bool

    public init(displayMode: String?, canCycle: Bool, shouldProbe: Bool) {
        self.displayMode = displayMode
        self.canCycle = canCycle
        self.shouldProbe = shouldProbe
    }
}

/// Keeps Claude Code's permission-mode presentation and control path from
/// leaking into providers that assign different meanings to the same terminal
/// keys. In particular, Pi uses Shift+Tab for thinking-level cycling and has no
/// built-in Claude-style plan mode.
public enum PermissionModeSurfacePolicy {
    public static func decision(
        agentID: AgentID,
        rawMode: String?,
        hasTTY: Bool,
        isInTmux: Bool
    ) -> PermissionModeSurfaceDecision {
        guard agentID == .claudeCode else {
            return PermissionModeSurfaceDecision(
                displayMode: nil,
                canCycle: false,
                shouldProbe: false
            )
        }

        return PermissionModeSurfaceDecision(
            displayMode: rawMode,
            canCycle: hasTTY,
            shouldProbe: hasTTY && !isInTmux
        )
    }

    public static func acceptsStateUpdates(for agentID: AgentID) -> Bool {
        agentID == .claudeCode
    }
}
