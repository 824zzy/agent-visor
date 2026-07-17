import Foundation

public enum CursorHostedSessionLiveness: Equatable, Sendable {
    case live
    case recent
    case drop
}

public enum CursorHostedSessionLivenessPolicy {
    public static func classify(
        hasTTY: Bool,
        entrypoint: String,
        processAlive: Bool,
        isTerminalStatus: Bool,
        transcriptModifiedAt: TimeInterval?,
        now: TimeInterval,
        observedWindowSeconds: TimeInterval,
        hasPendingUserAction: Bool = false
    ) -> CursorHostedSessionLiveness {
        if isTerminalStatus { return .drop }
        if hasPendingUserAction { return .live }

        if hasTTY {
            return processAlive ? .live : .drop
        }

        let normalizedEntrypoint = entrypoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedEntrypoint == "claude-vscode" else {
            return processAlive ? .live : .drop
        }

        guard let transcriptModifiedAt else {
            return .drop
        }

        let age = now - transcriptModifiedAt
        guard age >= 0, age <= observedWindowSeconds else {
            return .drop
        }

        return processAlive ? .live : .recent
    }
}
