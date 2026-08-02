import Foundation

/// Why a session is asking for the user's attention.
public enum AttentionKind: Equatable, Sendable {
    /// A tool is blocked waiting on approve/deny. `toolUseId` distinguishes
    /// successive approvals so each gets its own notification.
    case approval(toolUseId: String)
    /// The agent finished its turn and it's the user's move. Identity stays
    /// stable for the continuous Ready episode; leaving Ready resolves it so
    /// a later completion can notify again.
    case yourTurn
}

/// One session currently needing attention.
public struct AttentionItem: Equatable, Sendable {
    public let sessionId: String
    public let kind: AttentionKind

    public init(sessionId: String, kind: AttentionKind) {
        self.sessionId = sessionId
        self.kind = kind
    }

    /// Stable identity for de-duplication. Approval identity follows the
    /// explicit tool request. Completion identity follows the continuous
    /// Ready episode and becomes eligible again only after it resolves.
    public var dedupeKey: String {
        switch kind {
        case .approval(let toolUseId):
            return "\(sessionId)|approval|\(toolUseId)"
        case .yourTurn:
            return "\(sessionId)|turn"
        }
    }
}

public struct AttentionReconcileResult: Equatable, Sendable {
    /// Items that crossed into "needs attention" since the last reconcile
    /// — the ones to post a notification for.
    public let newItems: [AttentionItem]
    /// Dedupe keys whose attention has resolved — the delivered
    /// notifications to retract.
    public let resolvedKeys: [String]
    /// The full current key set — becomes the next reconcile's
    /// `previouslyNotified`.
    public let currentKeys: Set<String>
    /// Number of sessions needing attention right now — the badge count.
    public let totalCount: Int

    public init(
        newItems: [AttentionItem],
        resolvedKeys: [String],
        currentKeys: Set<String>,
        totalCount: Int
    ) {
        self.newItems = newItems
        self.resolvedKeys = resolvedKeys
        self.currentKeys = currentKeys
        self.totalCount = totalCount
    }
}

/// Diffs the current attention set against what's already been notified.
/// Pure so the notify/badge policy is unit-testable without
/// UNUserNotificationCenter, a dock tile, or live sessions.
public enum AttentionReconciler {
    public static func reconcile(
        current: [AttentionItem],
        previouslyNotified: Set<String>
    ) -> AttentionReconcileResult {
        let currentKeys = Set(current.map(\.dedupeKey))
        // Preserve input order for newItems (stable notification order).
        var seen: Set<String> = []
        let newItems = current.filter { item in
            let key = item.dedupeKey
            guard !previouslyNotified.contains(key), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        let resolved = previouslyNotified.subtracting(currentKeys)
        return AttentionReconcileResult(
            newItems: newItems,
            resolvedKeys: Array(resolved),
            currentKeys: currentKeys,
            totalCount: currentKeys.count
        )
    }
}
