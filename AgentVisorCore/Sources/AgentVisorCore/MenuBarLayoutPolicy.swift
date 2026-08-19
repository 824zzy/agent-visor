import CoreGraphics
import Foundation

public enum MenuBarEdgeSource: Equatable, Sendable {
    case ownerCache
    case ownerLocalMenu
    case ownerAccessibility(onTargetScreen: Bool)
    case screenWindowList
}

public struct MenuBarEdgeEvidence: Equatable, Sendable {
    public let generation: UInt64
    public let requestID: UInt64
    public let ownerBundleID: String?
    public let edge: CGFloat
    public let source: MenuBarEdgeSource

    public init(
        generation: UInt64,
        requestID: UInt64 = 0,
        ownerBundleID: String?,
        edge: CGFloat,
        source: MenuBarEdgeSource
    ) {
        self.generation = generation
        self.requestID = requestID
        self.ownerBundleID = ownerBundleID
        self.edge = edge
        self.source = source
    }
}

public struct MenuBarLayoutSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let targetScreenID: String
    public let ownerBundleID: String?
    public let ownerIsResolved: Bool
    public let evidence: MenuBarEdgeEvidence?
    public let latestRequestID: UInt64

    public init(
        generation: UInt64,
        targetScreenID: String,
        ownerBundleID: String?,
        ownerIsResolved: Bool,
        evidence: MenuBarEdgeEvidence?,
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

public enum MenuBarLayoutPolicy {
    public static func begin(
        generation: UInt64,
        targetScreenID: String,
        ownerBundleID: String?,
        ownerIsResolved: Bool,
        cachedOwnerEdge: CGFloat?,
        localOwnerEdge: CGFloat? = nil
    ) -> MenuBarLayoutSnapshot {
        let initialEvidence: MenuBarEdgeEvidence?
        if ownerIsResolved,
           let ownerBundleID,
           let localOwnerEdge,
           localOwnerEdge > 0 {
            initialEvidence = MenuBarEdgeEvidence(
                generation: generation,
                ownerBundleID: ownerBundleID,
                edge: localOwnerEdge,
                source: .ownerLocalMenu
            )
        } else if ownerIsResolved,
                  let ownerBundleID,
                  let cachedOwnerEdge,
                  cachedOwnerEdge > 0 {
            initialEvidence = MenuBarEdgeEvidence(
                generation: generation,
                ownerBundleID: ownerBundleID,
                edge: cachedOwnerEdge,
                source: .ownerCache
            )
        } else {
            initialEvidence = nil
        }

        return MenuBarLayoutSnapshot(
            generation: generation,
            targetScreenID: targetScreenID,
            ownerBundleID: ownerBundleID,
            ownerIsResolved: ownerIsResolved,
            evidence: initialEvidence,
            latestRequestID: 0
        )
    }

    public static func applying(
        _ evidence: MenuBarEdgeEvidence,
        to snapshot: MenuBarLayoutSnapshot
    ) -> MenuBarLayoutSnapshot {
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

        return MenuBarLayoutSnapshot(
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
        snapshot: MenuBarLayoutSnapshot,
        margin: CGFloat
    ) -> CGFloat {
        guard let edge = renderedEdge(for: snapshot),
              edge < available else {
            return 0
        }

        return max(0, available - edge - margin)
    }

    public static func renderedEdge(
        for snapshot: MenuBarLayoutSnapshot
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
