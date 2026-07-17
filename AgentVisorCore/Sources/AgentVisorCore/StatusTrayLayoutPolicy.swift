import CoreGraphics
import Foundation

public struct StatusTrayLayoutSnapshot: Equatable, Sendable {
    public let targetScreenID: String
    public let leftEdge: CGFloat?
    public let pendingContractionEdge: CGFloat?
    public let pendingContractionSince: TimeInterval?

    public init(
        targetScreenID: String,
        leftEdge: CGFloat?,
        pendingContractionEdge: CGFloat? = nil,
        pendingContractionSince: TimeInterval? = nil
    ) {
        self.targetScreenID = targetScreenID
        self.leftEdge = leftEdge
        self.pendingContractionEdge = pendingContractionEdge
        self.pendingContractionSince = pendingContractionSince
    }
}

public enum StatusTrayLayoutPolicy {
    public static func begin(
        targetScreenID: String,
        observedLeftEdge: CGFloat?
    ) -> StatusTrayLayoutSnapshot {
        StatusTrayLayoutSnapshot(
            targetScreenID: targetScreenID,
            leftEdge: reliableEdge(observedLeftEdge),
            pendingContractionEdge: nil,
            pendingContractionSince: nil
        )
    }

    public static func applying(
        observedLeftEdge: CGFloat?,
        observedAt: TimeInterval,
        contractionConfirmationInterval: TimeInterval = 0.75,
        targetScreenID: String,
        to snapshot: StatusTrayLayoutSnapshot
    ) -> StatusTrayLayoutSnapshot {
        guard targetScreenID == snapshot.targetScreenID else {
            return begin(
                targetScreenID: targetScreenID,
                observedLeftEdge: observedLeftEdge
            )
        }
        guard let observedLeftEdge = reliableEdge(observedLeftEdge) else {
            guard snapshot.pendingContractionSince != nil else { return snapshot }
            return StatusTrayLayoutSnapshot(
                targetScreenID: targetScreenID,
                leftEdge: snapshot.leftEdge,
                pendingContractionEdge: nil,
                pendingContractionSince: nil
            )
        }
        if let currentLeftEdge = snapshot.leftEdge,
           observedLeftEdge < currentLeftEdge {
            if let pendingEdge = snapshot.pendingContractionEdge,
               abs(pendingEdge - observedLeftEdge) <= 1,
               let pendingSince = snapshot.pendingContractionSince,
               observedAt - pendingSince >= contractionConfirmationInterval {
                return StatusTrayLayoutSnapshot(
                    targetScreenID: targetScreenID,
                    leftEdge: observedLeftEdge,
                    pendingContractionEdge: nil,
                    pendingContractionSince: nil
                )
            }
            let continuesPendingContraction = snapshot.pendingContractionEdge.map {
                abs($0 - observedLeftEdge) <= 1
            } ?? false
            return StatusTrayLayoutSnapshot(
                targetScreenID: targetScreenID,
                leftEdge: currentLeftEdge,
                pendingContractionEdge: observedLeftEdge,
                pendingContractionSince: continuesPendingContraction
                    ? snapshot.pendingContractionSince ?? observedAt
                    : observedAt
            )
        }
        return StatusTrayLayoutSnapshot(
            targetScreenID: targetScreenID,
            leftEdge: observedLeftEdge,
            pendingContractionEdge: nil,
            pendingContractionSince: nil
        )
    }

    public static func safeWidth(
        availableFrom: CGFloat,
        snapshot: StatusTrayLayoutSnapshot,
        margin: CGFloat
    ) -> CGFloat {
        guard let leftEdge = snapshot.leftEdge else { return 0 }
        return max(0, leftEdge - availableFrom - margin)
    }

    private static func reliableEdge(_ edge: CGFloat?) -> CGFloat? {
        guard let edge, edge.isFinite, edge > 0 else { return nil }
        return edge
    }
}
