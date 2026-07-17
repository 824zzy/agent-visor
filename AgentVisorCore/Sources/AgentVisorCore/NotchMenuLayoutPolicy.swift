import CoreGraphics
import Foundation

public enum NotchMenuEdgeSource: Equatable, Sendable {
    case ownerCache
    case ownerLocalMenu
    case ownerAccessibility(onTargetScreen: Bool)
    case screenWindowList
}

public struct NotchMenuEdgeEvidence: Equatable, Sendable {
    public let generation: UInt64
    public let requestID: UInt64
    public let ownerBundleID: String?
    public let edge: CGFloat
    public let source: NotchMenuEdgeSource

    public init(
        generation: UInt64,
        requestID: UInt64 = 0,
        ownerBundleID: String?,
        edge: CGFloat,
        source: NotchMenuEdgeSource
    ) {
        self.generation = generation
        self.requestID = requestID
        self.ownerBundleID = ownerBundleID
        self.edge = edge
        self.source = source
    }
}

public struct NotchMenuLayoutSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let targetScreenID: String
    public let ownerBundleID: String?
    public let ownerIsResolved: Bool
    public let evidence: NotchMenuEdgeEvidence?
    public let latestRequestID: UInt64

    public init(
        generation: UInt64,
        targetScreenID: String,
        ownerBundleID: String?,
        ownerIsResolved: Bool,
        evidence: NotchMenuEdgeEvidence?,
        latestRequestID: UInt64 = 0
    ) {
        self.generation = generation
        self.targetScreenID = targetScreenID
        self.ownerBundleID = ownerBundleID
        self.ownerIsResolved = ownerIsResolved
        self.evidence = evidence
        self.latestRequestID = latestRequestID
    }
}

public enum NotchMenuLayoutPolicy {
    public static func begin(
        generation: UInt64,
        targetScreenID: String,
        ownerBundleID: String?,
        ownerIsResolved: Bool,
        cachedOwnerEdge: CGFloat?,
        localOwnerEdge: CGFloat? = nil
    ) -> NotchMenuLayoutSnapshot {
        let initialEvidence: NotchMenuEdgeEvidence?
        if ownerIsResolved,
           let ownerBundleID,
           let localOwnerEdge,
           localOwnerEdge > 0 {
            initialEvidence = NotchMenuEdgeEvidence(
                generation: generation,
                ownerBundleID: ownerBundleID,
                edge: localOwnerEdge,
                source: .ownerLocalMenu
            )
        } else if ownerIsResolved,
                  let ownerBundleID,
                  let cachedOwnerEdge,
                  cachedOwnerEdge > 0 {
            initialEvidence = NotchMenuEdgeEvidence(
                generation: generation,
                ownerBundleID: ownerBundleID,
                edge: cachedOwnerEdge,
                source: .ownerCache
            )
        } else {
            initialEvidence = nil
        }

        return NotchMenuLayoutSnapshot(
            generation: generation,
            targetScreenID: targetScreenID,
            ownerBundleID: ownerBundleID,
            ownerIsResolved: ownerIsResolved,
            evidence: initialEvidence,
            latestRequestID: 0
        )
    }

    public static func applying(
        _ evidence: NotchMenuEdgeEvidence,
        to snapshot: NotchMenuLayoutSnapshot
    ) -> NotchMenuLayoutSnapshot {
        guard evidence.generation == snapshot.generation,
              evidence.requestID >= snapshot.latestRequestID,
              evidence.edge > 0 else {
            return snapshot
        }

        switch evidence.source {
        case .ownerCache, .ownerLocalMenu, .ownerAccessibility:
            guard snapshot.ownerIsResolved,
                  let ownerBundleID = snapshot.ownerBundleID,
                  evidence.ownerBundleID == ownerBundleID else {
                return snapshot
            }
        case .screenWindowList:
            break
        }

        return NotchMenuLayoutSnapshot(
            generation: snapshot.generation,
            targetScreenID: snapshot.targetScreenID,
            ownerBundleID: snapshot.ownerBundleID,
            ownerIsResolved: snapshot.ownerIsResolved,
            evidence: evidence,
            latestRequestID: evidence.requestID
        )
    }

    public static func safeWidth(
        available: CGFloat,
        snapshot: NotchMenuLayoutSnapshot,
        margin: CGFloat
    ) -> CGFloat {
        guard let edge = renderedEdge(for: snapshot),
              edge < available else {
            return 0
        }

        return max(0, available - edge - margin)
    }

    public static func renderedEdge(
        for snapshot: NotchMenuLayoutSnapshot
    ) -> CGFloat? {
        guard let evidence = snapshot.evidence,
              evidence.generation == snapshot.generation,
              evidence.edge > 0 else {
            return nil
        }

        switch evidence.source {
        case .ownerCache, .ownerLocalMenu, .ownerAccessibility:
            guard snapshot.ownerIsResolved,
                  let ownerBundleID = snapshot.ownerBundleID,
                  evidence.ownerBundleID == ownerBundleID else {
                return nil
            }
        case .screenWindowList:
            break
        }
        return evidence.edge
    }
}
