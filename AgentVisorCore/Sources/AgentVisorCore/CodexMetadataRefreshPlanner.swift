import Foundation

public enum CodexMetadataRefreshAction: Equatable, Sendable {
    case refreshKnownSessions
    case rediscoverSessions
    case scheduleRediscovery(after: TimeInterval)
}

public enum CodexMetadataRefreshPlanner {
    public static let defaultRediscoveryCooldownSeconds: TimeInterval = 10

    public static func actionsForMetadataChange(
        now: Date,
        lastRediscoveryAt: Date?,
        hasScheduledRediscovery: Bool,
        requiresRediscovery: Bool = true,
        rediscoveryCooldownSeconds: TimeInterval = defaultRediscoveryCooldownSeconds
    ) -> [CodexMetadataRefreshAction] {
        guard requiresRediscovery else {
            return [.refreshKnownSessions]
        }

        guard let lastRediscoveryAt else {
            return [.refreshKnownSessions, .rediscoverSessions]
        }

        let elapsed = now.timeIntervalSince(lastRediscoveryAt)
        if elapsed >= rediscoveryCooldownSeconds {
            return [.refreshKnownSessions, .rediscoverSessions]
        }

        guard !hasScheduledRediscovery else {
            return [.refreshKnownSessions]
        }

        return [
            .refreshKnownSessions,
            .scheduleRediscovery(after: max(0, rediscoveryCooldownSeconds - elapsed))
        ]
    }
}
