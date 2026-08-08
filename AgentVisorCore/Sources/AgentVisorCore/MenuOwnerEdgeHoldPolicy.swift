import CoreGraphics
import Foundation

/// Stabilizes the application-menu right edge (the left pill-bar boundary) so a
/// transient loss of ownership or a momentarily wider menu measurement cannot
/// collapse the pill bar. It is the left-side mirror of `StatusTrayLayoutPolicy`:
/// for the left boundary a *larger* edge means *less* room, so a larger edge
/// (contraction) must persist before it applies, while a smaller edge (more
/// room) applies immediately. A missing/unreliable observation holds the last
/// reliable edge rather than collapsing to zero.
public struct MenuOwnerEdgeHoldSnapshot: Equatable, Sendable {
    public let targetScreenID: String
    public let heldEdge: CGFloat?
    public let pendingWiderEdge: CGFloat?
    public let pendingSince: TimeInterval?

    public init(
        targetScreenID: String,
        heldEdge: CGFloat?,
        pendingWiderEdge: CGFloat? = nil,
        pendingSince: TimeInterval? = nil
    ) {
        self.targetScreenID = targetScreenID
        self.heldEdge = heldEdge
        self.pendingWiderEdge = pendingWiderEdge
        self.pendingSince = pendingSince
    }
}

public enum MenuOwnerEdgeHoldPolicy {
    public static func begin(
        targetScreenID: String,
        observedEdge: CGFloat?
    ) -> MenuOwnerEdgeHoldSnapshot {
        MenuOwnerEdgeHoldSnapshot(
            targetScreenID: targetScreenID,
            heldEdge: reliableEdge(observedEdge)
        )
    }

    public static func applying(
        observedEdge: CGFloat?,
        observedAt: TimeInterval,
        contractionConfirmationInterval: TimeInterval = 0.75,
        targetScreenID: String,
        to snapshot: MenuOwnerEdgeHoldSnapshot
    ) -> MenuOwnerEdgeHoldSnapshot {
        guard targetScreenID == snapshot.targetScreenID else {
            return begin(targetScreenID: targetScreenID, observedEdge: observedEdge)
        }
        guard let observed = reliableEdge(observedEdge) else {
            // Transient loss of a reliable edge: keep the last held edge and
            // cancel any pending contraction.
            guard snapshot.pendingSince != nil else { return snapshot }
            return MenuOwnerEdgeHoldSnapshot(
                targetScreenID: targetScreenID,
                heldEdge: snapshot.heldEdge
            )
        }
        if let held = snapshot.heldEdge, observed > held {
            // Larger edge = less room = contraction. Confirm persistence first.
            if let pending = snapshot.pendingWiderEdge,
               abs(pending - observed) <= 1,
               let since = snapshot.pendingSince,
               observedAt - since >= contractionConfirmationInterval {
                return MenuOwnerEdgeHoldSnapshot(
                    targetScreenID: targetScreenID,
                    heldEdge: observed
                )
            }
            let continuesPending = snapshot.pendingWiderEdge.map {
                abs($0 - observed) <= 1
            } ?? false
            return MenuOwnerEdgeHoldSnapshot(
                targetScreenID: targetScreenID,
                heldEdge: held,
                pendingWiderEdge: observed,
                pendingSince: continuesPending ? snapshot.pendingSince ?? observedAt : observedAt
            )
        }
        // Smaller-or-equal edge = same or more room: apply immediately.
        return MenuOwnerEdgeHoldSnapshot(
            targetScreenID: targetScreenID,
            heldEdge: observed
        )
    }

    public static func heldEdge(_ snapshot: MenuOwnerEdgeHoldSnapshot) -> CGFloat? {
        snapshot.heldEdge
    }

    private static func reliableEdge(_ edge: CGFloat?) -> CGFloat? {
        guard let edge, edge.isFinite, edge > 0 else { return nil }
        return edge
    }
}
