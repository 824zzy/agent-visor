import Foundation

public struct ComposerSnapshotLedgerEntry: Equatable, Sendable {
    public let submissionId: String
    public let sessionId: String
    public let pendingEchoId: String?

    public init(submissionId: String, sessionId: String, pendingEchoId: String?) {
        self.submissionId = submissionId
        self.sessionId = sessionId
        self.pendingEchoId = pendingEchoId
    }
}

public enum ComposerSnapshotLifecycleEvent: Equatable, Sendable {
    case canonical(sessionId: String, pendingEchoId: String)
    case expired(sessionId: String, pendingEchoId: String)
    case phaseCompleted(sessionId: String)
    case sessionChanged(sessionId: String)
}

/// Selects only the snapshots made obsolete by one authoritative lifecycle
/// event. The caller owns the actual ledger; Core prevents a canonical row or
/// session transition from deleting an unrelated delivery's recovery data.
public enum ComposerSnapshotLifecyclePolicy {
    public enum DeliveredAckDisposition: Equatable, Sendable {
        case removeSnapshot
        case retainRecoverySnapshot
        case ignore
    }

    /// Decides whether a successful sender acknowledgement may release the
    /// exact app-owned snapshot. A sender acknowledgement is not canonical
    /// transcript evidence: if expiry already promoted the snapshot into a
    /// recovery entry, the app snapshot remains owned by that card until a
    /// canonical row, dismiss, or retry transition consumes it.
    public static func deliveredAckDisposition(
        snapshot: ComposerSendRecoverySnapshot?,
        deliveryID: String,
        sessionID: String,
        generationID: String,
        recoveryEntries: [ComposerSendRecoveryEntry]
    ) -> DeliveredAckDisposition {
        guard let snapshot,
              snapshot.deliveryID == deliveryID,
              snapshot.sessionID == sessionID,
              snapshot.generationID == generationID else {
            return .ignore
        }
        if recoveryEntries.contains(where: {
            $0.snapshot.deliveryID == deliveryID
                && $0.snapshot.sessionID == sessionID
                && $0.snapshot.generationID == generationID
        }) {
            return .retainRecoverySnapshot
        }
        return .removeSnapshot
    }

    public static func submissionIdsToRemove(
        entries: [ComposerSnapshotLedgerEntry],
        event: ComposerSnapshotLifecycleEvent
    ) -> Set<String> {
        entries.reduce(into: Set<String>()) { result, entry in
            switch event {
            case .canonical(let sessionId, let echoId), .expired(let sessionId, let echoId):
                if entry.sessionId == sessionId && entry.pendingEchoId == echoId {
                    result.insert(entry.submissionId)
                }
            case .phaseCompleted(let sessionId), .sessionChanged(let sessionId):
                if entry.sessionId == sessionId { result.insert(entry.submissionId) }
            }
        }
    }
}
