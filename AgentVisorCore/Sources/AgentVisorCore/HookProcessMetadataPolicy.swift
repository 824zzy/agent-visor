public struct HookProcessMetadata: Equatable, Sendable {
    public let pid: Int?
    public let tty: String?

    public init(pid: Int?, tty: String?) {
        self.pid = pid
        self.tty = tty
    }
}

public enum HookProcessMetadataPolicy {
    public static func merge(
        existing: HookProcessMetadata,
        reported: HookProcessMetadata,
        sharesProcessAcrossSessions: Bool
    ) -> HookProcessMetadata {
        guard !sharesProcessAcrossSessions else { return existing }
        return HookProcessMetadata(
            pid: reported.pid,
            tty: reported.tty ?? existing.tty
        )
    }

    public static func shouldRemoveCollidingSession(
        incomingSharesProcessAcrossSessions: Bool,
        existingSharesProcessAcrossSessions: Bool
    ) -> Bool {
        !incomingSharesProcessAcrossSessions && !existingSharesProcessAcrossSessions
    }
}
