import Foundation

public struct PendingPillMovement: Equatable, Sendable {
    public let navigationDate: Date
    public let deadline: Date

    public init(navigationDate: Date, deadline: Date) {
        self.navigationDate = navigationDate
        self.deadline = deadline
    }
}

public enum PillMovementGracePolicy {
    public static let defaultDelay = ReadyAttentionPolicy.defaultPositionHold

    public static func pendingMove(
        existing: PendingPillMovement?,
        navigationAt: Date,
        delay: TimeInterval = defaultDelay
    ) -> PendingPillMovement {
        PendingPillMovement(
            navigationDate: max(existing?.navigationDate ?? navigationAt, navigationAt),
            deadline: existing?.deadline
                ?? navigationAt.addingTimeInterval(max(0, delay))
        )
    }

    public static func isReadyToCommit(
        _ pending: PendingPillMovement,
        now: Date
    ) -> Bool {
        now >= pending.deadline
    }
}
