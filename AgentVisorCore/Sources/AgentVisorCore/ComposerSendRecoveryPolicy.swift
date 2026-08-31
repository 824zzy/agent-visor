import Foundation

/// Stable metadata for an attachment retained by a failed or canceled
/// submission. Core does not retain AppKit images, but it does retain the
/// path and both full/thumbnail byte counts used by admission and cleanup.
public struct ComposerSendRecoveryAttachment: Equatable, Sendable {
    public let id: String
    public let path: String
    public let contentBytes: Int
    public let thumbnailBytes: Int

    public init(
        id: String,
        path: String,
        contentBytes: Int,
        thumbnailBytes: Int
    ) {
        self.id = id
        self.path = path
        self.contentBytes = max(0, contentBytes)
        self.thumbnailBytes = max(0, thumbnailBytes)
    }

    public var retainedBytes: Int {
        id.utf8.count + path.utf8.count + contentBytes + thumbnailBytes
    }
}

/// The provider-neutral identity and immutable draft captured for one send.
/// The application keeps the actual image values beside this record; Core
/// carries their stable IDs so recovery decisions cannot accidentally mix
/// attachments from a newer composer edit.
public struct ComposerSendRecoverySnapshot: Equatable, Sendable {
    public let deliveryID: String
    public let sessionID: String
    public let generationID: String
    public let text: String
    public let attachmentIDs: [String]
    public let attachmentMetadata: [ComposerSendRecoveryAttachment]
    public let pendingEchoID: String?
    public let submittedRevision: Int
    public let clearedRevision: Int

    public init(
        deliveryID: String,
        sessionID: String,
        generationID: String,
        text: String,
        attachmentIDs: [String],
        attachmentMetadata: [ComposerSendRecoveryAttachment] = [],
        pendingEchoID: String?,
        submittedRevision: Int,
        clearedRevision: Int
    ) {
        self.deliveryID = deliveryID
        self.sessionID = sessionID
        self.generationID = generationID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.attachmentMetadata = attachmentMetadata
        self.pendingEchoID = pendingEchoID
        self.submittedRevision = submittedRevision
        self.clearedRevision = clearedRevision
    }

    /// Approximate retained bytes, including full image and thumbnail data.
    /// Callers use this to explain an admission rejection without duplicating
    /// the ledger's accounting policy.
    public var estimatedBytes: Int {
        deliveryID.utf8.count
            + sessionID.utf8.count
            + generationID.utf8.count
            + text.utf8.count
            + attachmentIDs.reduce(0) { $0 + $1.utf8.count }
            + attachmentMetadata.reduce(0) { $0 + $1.retainedBytes }
            + (pendingEchoID?.utf8.count ?? 0)
    }
}

public enum ComposerSendRecoveryState: Equatable, Sendable {
    case failed(reason: String)
    /// One or more terminal writes may have succeeded, but the provider did
    /// not confirm the complete ordered submission. Ordinary Retry is unsafe
    /// because it could duplicate an image or text already accepted.
    case uncertain(reason: String)
    case retrying(deliveryID: String)
    /// The provider accepted the send, but its authoritative transcript row
    /// has not arrived. Keep attachment metadata until exact confirmation.
    case awaitingCanonical(deliveryID: String)
}

public struct ComposerSendRecoveryEntry: Equatable, Sendable, Identifiable {
    public let recoveryID: String
    public let snapshot: ComposerSendRecoverySnapshot
    public let state: ComposerSendRecoveryState
    /// All optimistic echoes associated with this recovery card, including a
    /// superseded attempt. Canonical reconciliation consumes one exact ID.
    public let pendingEchoIDs: [String]

    public var id: String { recoveryID }

    public init(
        recoveryID: String,
        snapshot: ComposerSendRecoverySnapshot,
        state: ComposerSendRecoveryState,
        pendingEchoIDs: [String]
    ) {
        self.recoveryID = recoveryID
        self.snapshot = snapshot
        self.state = state
        self.pendingEchoIDs = pendingEchoIDs
    }
}

public struct ComposerSendRecoveryRetry: Equatable, Sendable {
    public let snapshot: ComposerSendRecoverySnapshot
    public let isNew: Bool

    public init(snapshot: ComposerSendRecoverySnapshot, isNew: Bool) {
        self.snapshot = snapshot
        self.isNew = isNew
    }
}

public enum ComposerSendRecoveryAdmission: Equatable, Sendable {
    case retained
    case rejected(reason: String)
}

/// Stable, accessible card semantics for the app surface. SwiftUI owns the
/// buttons and actions; Core owns when those actions are allowed and which
/// exact recovery card they describe.
public struct ComposerSendRecoveryCardPresentation: Equatable, Sendable {
    public let recoveryID: String
    public let title: String
    public let reason: String
    public let attachmentCount: Int
    public let canRetry: Bool
    public let canDismiss: Bool
    public let canRestore: Bool
    public let canConfirmRiskRetry: Bool
    public let accessibilityLabel: String

    public init(
        recoveryID: String,
        title: String,
        reason: String,
        attachmentCount: Int,
        canRetry: Bool,
        canDismiss: Bool,
        canRestore: Bool = false,
        canConfirmRiskRetry: Bool = false,
        accessibilityLabel: String
    ) {
        self.recoveryID = recoveryID
        self.title = title
        self.reason = reason
        self.attachmentCount = attachmentCount
        self.canRetry = canRetry
        self.canDismiss = canDismiss
        self.canRestore = canRestore
        self.canConfirmRiskRetry = canConfirmRiskRetry
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum ComposerSendRecoveryPresentationPolicy {
    public static func presentation(
        for entry: ComposerSendRecoveryEntry
    ) -> ComposerSendRecoveryCardPresentation {
        switch entry.state {
        case .failed(let reason):
            return ComposerSendRecoveryCardPresentation(
                recoveryID: entry.recoveryID,
                title: "Message not sent",
                reason: reason,
                attachmentCount: entry.snapshot.attachmentIDs.count,
                canRetry: true,
                canDismiss: true,
                accessibilityLabel: "Failed message recovery"
            )
        case .uncertain(let reason):
            return ComposerSendRecoveryCardPresentation(
                recoveryID: entry.recoveryID,
                title: "Delivery uncertain",
                reason: reason,
                attachmentCount: entry.snapshot.attachmentIDs.count,
                canRetry: false,
                canDismiss: true,
                canRestore: true,
                canConfirmRiskRetry: true,
                accessibilityLabel: "Delivery uncertain; review before retrying"
            )
        case .retrying:
            return ComposerSendRecoveryCardPresentation(
                recoveryID: entry.recoveryID,
                title: "Sending message again",
                reason: "The original text and attachments are retained.",
                attachmentCount: entry.snapshot.attachmentIDs.count,
                canRetry: false,
                canDismiss: false,
                accessibilityLabel: "Retrying failed message"
            )
        case .awaitingCanonical:
            return ComposerSendRecoveryCardPresentation(
                recoveryID: entry.recoveryID,
                title: "Message sent",
                reason: "Waiting for the agent transcript to confirm delivery.",
                attachmentCount: entry.snapshot.attachmentIDs.count,
                canRetry: false,
                canDismiss: false,
                accessibilityLabel: "Message sent, waiting for transcript confirmation"
            )
        }
    }
}

/// Bounded, identity-scoped recovery ledger for failed sends.
///
/// This is deliberately a value type. WindowComposer owns it per session
/// generation, while tests and other surfaces can exercise the exact state
/// transitions without a SwiftUI runtime or hidden timers.
public struct ComposerSendRecoveryLedger: Sendable {
    // ponytail: 256 cards and the shared image aggregate budget keep recovery
    // metadata, paths, thumbnails, and full-image byte claims bounded. The
    // attachment-reference cap is shared with file cleanup. Raise a limit
    // only with coordinated persistence and user-visible recovery guidance.
    public static let maxRecords = 256
    public static let maxSnapshotBytes = ImageAttachmentAdmissionPolicy.maxAggregateBytes
    public static let maxRetainedAttachmentReferences = ImageAttachmentRetentionPolicy.maxRetainedAttachmentReferences
    public static let maxReasonBytes = 512
    public static let maxPendingEchoIDs = 32

    private var records: [String: ComposerSendRecoveryEntry] = [:]
    private var insertionOrder: [String] = []

    public init() {}

    public var allEntries: [ComposerSendRecoveryEntry] {
        insertionOrder.compactMap { records[$0] }
    }

    /// Attachment IDs still owned by any pending, retrying, awaiting, or
    /// failed recovery record. The app-side file adapter must consult this
    /// set before deleting either the full file or its thumbnail.
    public var retainedAttachmentIDs: Set<String> {
        Set(allEntries.flatMap { $0.snapshot.attachmentIDs })
    }

    public func retainsAttachment(_ attachmentID: String) -> Bool {
        retainedAttachmentIDs.contains(attachmentID)
    }

    public func entries(sessionID: String, generationID: String) -> [ComposerSendRecoveryEntry] {
        allEntries.filter {
            $0.snapshot.sessionID == sessionID && $0.snapshot.generationID == generationID
        }
    }

    public func entry(recoveryID: String) -> ComposerSendRecoveryEntry? {
        records[recoveryID]
    }

    /// Records a failed attempt. `false` means the bounded ledger could not
    /// retain the snapshot; the caller must keep the draft visible and provide
    /// a fail-safe message instead of silently dropping user content.
    @discardableResult
    public mutating func recordFailure(
        snapshot: ComposerSendRecoverySnapshot,
        reason: String
    ) -> Bool {
        admitFailure(snapshot: snapshot, reason: reason) == .retained
    }

    /// Retains a partial terminal delivery without presenting an unsafe
    /// one-click retry. The exact snapshot remains available for Restore,
    /// Dismiss, and an explicit risk-confirmed retry.
    @discardableResult
    public mutating func recordUncertain(
        snapshot: ComposerSendRecoverySnapshot,
        reason: String
    ) -> Bool {
        guard admitFailure(snapshot: snapshot, reason: reason) == .retained,
              let entry = records[snapshot.deliveryID] else { return false }
        records[snapshot.deliveryID] = ComposerSendRecoveryEntry(
            recoveryID: entry.recoveryID,
            snapshot: entry.snapshot,
            state: .uncertain(reason: boundedReason(reason)),
            pendingEchoIDs: entry.pendingEchoIDs
        )
        return true
    }

    /// Records expiry for the exact current pending echo in place. A retry
    /// keeps the original recovery identity even though its snapshot and
    /// delivery ID are replaced; admitting `snapshot` through
    /// `recordFailure` would create a second recovery record keyed by that
    /// replacement delivery ID.
    @discardableResult
    public mutating func recordFailureForPendingEcho(
        snapshot: ComposerSendRecoverySnapshot,
        pendingEchoID: String,
        reason: String
    ) -> Bool {
        guard !pendingEchoID.isEmpty,
              !reason.isEmpty,
              snapshot.pendingEchoID == pendingEchoID,
              isValid(snapshot),
              let recoveryID = insertionOrder.first(where: { recoveryID in
                  guard let entry = records[recoveryID] else { return false }
                  return entry.snapshot.sessionID == snapshot.sessionID
                      && entry.snapshot.generationID == snapshot.generationID
                      && entry.snapshot.deliveryID == snapshot.deliveryID
                      && entry.snapshot.pendingEchoID == pendingEchoID
                      && entry.pendingEchoIDs.contains(pendingEchoID)
              }),
              let existing = records[recoveryID] else {
            return false
        }

        // The side-map snapshot is only an identity witness for this
        // transition. The recovery entry remains authoritative: expiry must
        // not replace its retained retry snapshot or attachment metadata with
        // a newly reconstructed value from the app adapter.
        let nextState: ComposerSendRecoveryState
        switch existing.state {
        case .failed:
            // No provider write was admitted for a definitely failed
            // lineage, so ordinary Retry remains safe after its echo expires.
            nextState = .failed(reason: boundedReason(reason))
        case .uncertain, .retrying, .awaitingCanonical:
            // An uncertain, in-flight, or already-accepted send may have
            // reached the provider. Echo expiry only removes optimistic
            // evidence; it must never turn that lineage into an ordinary
            // one-click Retry that could duplicate text or attachments.
            nextState = .uncertain(reason: boundedReason(reason))
        }
        records[recoveryID] = ComposerSendRecoveryEntry(
            recoveryID: existing.recoveryID,
            snapshot: existing.snapshot,
            state: nextState,
            pendingEchoIDs: existing.pendingEchoIDs
        )
        return true
    }

    /// Admission is explicit so an app adapter can restore content when the
    /// bounded ledger is full or the immutable snapshot is too large. Existing
    /// actionable entries are never silently evicted.
    @discardableResult
    public mutating func admitFailure(
        snapshot: ComposerSendRecoverySnapshot,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        guard isValid(snapshot) else {
            return .rejected(reason: "The submitted message exceeds the recovery limit.")
        }
        guard !reason.isEmpty else {
            return .rejected(reason: "The send failed without a recoverable reason.")
        }
        let boundedReason = boundedReason(reason)
        let recoveryID = snapshot.deliveryID
        if let existing = records[recoveryID] {
            guard aggregateBytes() - snapshotBytes(existing.snapshot)
                    + snapshotBytes(snapshot) <= Self.maxSnapshotBytes,
                  !exceedsAttachmentReferenceCap(
                      snapshot: snapshot,
                      replacing: recoveryID
                  ) else {
                return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
            }
            let echoes = mergeEchoIDs(existing.pendingEchoIDs, snapshot.pendingEchoID)
            records[recoveryID] = ComposerSendRecoveryEntry(
                recoveryID: recoveryID,
                snapshot: snapshot,
                state: .failed(reason: boundedReason),
                pendingEchoIDs: echoes
            )
            return .retained
        }
        let entry = ComposerSendRecoveryEntry(
            recoveryID: recoveryID,
            snapshot: snapshot,
            state: .failed(reason: boundedReason),
            pendingEchoIDs: snapshot.pendingEchoID.map { [$0] } ?? []
        )
        guard makeRoom(for: entry) else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        records[recoveryID] = entry
        insertionOrder.append(recoveryID)
        return .retained
    }

    /// Starts one retry for a failed card. A second call while the exact
    /// replacement is in flight returns the same identity and performs no
    /// second transition or send.
    public mutating func beginRetry(
        recoveryID: String,
        sessionID: String,
        generationID: String,
        replacement: ComposerSendRecoverySnapshot,
        allowUncertain: Bool = false
    ) -> ComposerSendRecoveryRetry? {
        guard var existing = records[recoveryID],
              existing.snapshot.sessionID == sessionID,
              existing.snapshot.generationID == generationID,
              replacement.sessionID == sessionID,
              replacement.generationID == generationID,
              isValid(replacement) else { return nil }
        switch existing.state {
        case .retrying:
            return ComposerSendRecoveryRetry(snapshot: existing.snapshot, isNew: false)
        case .awaitingCanonical:
            return nil
        case .uncertain where !allowUncertain:
            return nil
        case .uncertain, .failed:
            existing = ComposerSendRecoveryEntry(
                recoveryID: recoveryID,
                snapshot: replacement,
                state: .retrying(deliveryID: replacement.deliveryID),
                pendingEchoIDs: mergeEchoIDs(
                    existing.pendingEchoIDs,
                    replacement.pendingEchoID
                )
            )
            records[recoveryID] = existing
            return ComposerSendRecoveryRetry(snapshot: replacement, isNew: true)
        }
    }

    /// Finishes only the exact retry currently owned by the card. Success
    /// retains the card in an awaiting-canonical state until the provider row
    /// confirms the exact active echo; failure returns it to an actionable
    /// state.
    @discardableResult
    public mutating func finishRetry(
        recoveryID: String,
        deliveryID: String,
        succeeded: Bool,
        reason: String = "Send failed"
    ) -> Bool {
        guard let existing = records[recoveryID],
              case .retrying(let activeDeliveryID) = existing.state,
              activeDeliveryID == deliveryID else { return false }
        if succeeded {
            records[recoveryID] = ComposerSendRecoveryEntry(
                recoveryID: recoveryID,
                snapshot: existing.snapshot,
                state: .awaitingCanonical(deliveryID: deliveryID),
                pendingEchoIDs: existing.pendingEchoIDs
            )
        } else {
            records[recoveryID] = ComposerSendRecoveryEntry(
                recoveryID: recoveryID,
                snapshot: existing.snapshot,
                state: .failed(reason: boundedReason(reason)),
                pendingEchoIDs: existing.pendingEchoIDs
            )
        }
        return true
    }

    /// Atomically records an uncertain retry result while keeping the one
    /// recovery identity and replacement snapshot owned by the retry. This
    /// must not be implemented as `finishRetry(false)` followed by
    /// `recordUncertain`: the latter keys admission by the replacement
    /// delivery ID and would create a duplicate record.
    @discardableResult
    public mutating func finishRetryUncertain(
        recoveryID: String,
        deliveryID: String,
        reason: String
    ) -> Bool {
        guard let existing = records[recoveryID],
              case .retrying(let activeDeliveryID) = existing.state,
              activeDeliveryID == deliveryID else { return false }
        records[recoveryID] = ComposerSendRecoveryEntry(
            recoveryID: existing.recoveryID,
            snapshot: existing.snapshot,
            state: .uncertain(reason: boundedReason(reason)),
            pendingEchoIDs: existing.pendingEchoIDs
        )
        return true
    }

    /// Dismisses only the exact failed card in the current session generation.
    @discardableResult
    public mutating func dismiss(
        recoveryID: String,
        sessionID: String,
        generationID: String
    ) -> Bool {
        guard let existing = records[recoveryID],
              existing.snapshot.sessionID == sessionID,
              existing.snapshot.generationID == generationID else { return false }
        switch existing.state {
        case .failed, .uncertain:
            break
        case .retrying, .awaitingCanonical:
            return false
        }
        remove(recoveryID: recoveryID)
        return true
    }

    /// Reconciles a canonical row by exact optimistic-echo identity. A stale
    /// row from a different session generation is intentionally ignored.
    public mutating func reconcileCanonical(
        sessionID: String,
        generationID: String,
        pendingEchoID: String
    ) -> [String] {
        let removed = allEntries.compactMap { entry -> String? in
            guard entry.snapshot.sessionID == sessionID,
                  entry.snapshot.generationID == generationID,
                  entry.pendingEchoIDs.contains(pendingEchoID) else { return nil }
            switch entry.state {
            case .failed:
                return entry.recoveryID
            case .uncertain:
                // Once a retry has replaced the snapshot, the old echo is
                // history only. Require the active replacement identity so a
                // late original canonical row cannot release an uncertain
                // retry's retained snapshot.
                guard entry.snapshot.pendingEchoID == pendingEchoID else { return nil }
                return entry.recoveryID
            case .retrying(let activeDeliveryID), .awaitingCanonical(let activeDeliveryID):
                // A late canonical row for the original attempt must not
                // consume a newer retry. Only the active retry's exact echo
                // releases the retained snapshot and attachment metadata.
                guard entry.snapshot.pendingEchoID == pendingEchoID,
                      activeDeliveryID == entry.snapshot.deliveryID else { return nil }
                return entry.recoveryID
            }
        }
        for recoveryID in removed { remove(recoveryID: recoveryID) }
        return removed
    }

    /// Invalidates recovery owned by one session generation. Other sessions
    /// remain intact so a stale async failure cannot restore into them.
    public mutating func invalidate(sessionID: String, generationID: String) {
        let ids = allEntries.filter {
            $0.snapshot.sessionID == sessionID && $0.snapshot.generationID == generationID
        }.map(\.recoveryID)
        for recoveryID in ids { remove(recoveryID: recoveryID) }
    }

    /// The post-failure composer can be cleared for retry only when the user
    /// is looking at the exact restored snapshot and has made no new edit.
    public static func shouldClearComposerForRetry(
        snapshot: ComposerSendRecoverySnapshot,
        currentText: String,
        currentAttachmentIDs: [String],
        currentRevision: Int
    ) -> Bool {
        currentText == snapshot.text
            && currentAttachmentIDs == snapshot.attachmentIDs
            && currentRevision == snapshot.clearedRevision + 1
    }

    /// Admission used while a submission is still live, before its provider
    /// result is known.  Live snapshots are retained so a failed send can be
    /// recovered; therefore the same aggregate-byte and unique-reference
    /// budgets apply before the composer is cleared.
    public static func canAdmitLiveSubmission(
        existing: [ComposerSendRecoverySnapshot],
        candidate: ComposerSendRecoverySnapshot
    ) -> Bool {
        guard existing.count < maxRecords,
              !candidate.deliveryID.isEmpty,
              !candidate.sessionID.isEmpty,
              !candidate.generationID.isEmpty,
              !candidate.text.isEmpty || !candidate.attachmentIDs.isEmpty,
              candidate.estimatedBytes <= maxSnapshotBytes else {
            return false
        }
        var bytes = 0
        var references = Set<String>()
        for snapshot in existing {
            guard !bytes.addingReportingOverflow(snapshot.estimatedBytes).overflow else {
                return false
            }
            bytes += snapshot.estimatedBytes
            references.formUnion(snapshot.attachmentIDs)
        }
        guard !bytes.addingReportingOverflow(candidate.estimatedBytes).overflow,
              bytes + candidate.estimatedBytes <= maxSnapshotBytes else {
            return false
        }
        references.formUnion(candidate.attachmentIDs)
        return references.count <= maxRetainedAttachmentReferences
    }

    private func isValid(_ snapshot: ComposerSendRecoverySnapshot) -> Bool {
        !snapshot.deliveryID.isEmpty
            && !snapshot.sessionID.isEmpty
            && !snapshot.generationID.isEmpty
            && snapshot.submittedRevision >= 0
            && snapshot.clearedRevision >= snapshot.submittedRevision
            && (!snapshot.text.isEmpty || !snapshot.attachmentIDs.isEmpty)
            && snapshotBytes(snapshot) <= Self.maxSnapshotBytes
            && attachmentMetadataMatches(snapshot)
    }

    private func snapshotBytes(_ snapshot: ComposerSendRecoverySnapshot) -> Int {
        snapshot.deliveryID.utf8.count
            + snapshot.sessionID.utf8.count
            + snapshot.generationID.utf8.count
            + snapshot.text.utf8.count
            + snapshot.attachmentIDs.reduce(0) { $0 + $1.utf8.count }
            + snapshot.attachmentMetadata.reduce(0) { $0 + $1.retainedBytes }
            + (snapshot.pendingEchoID?.utf8.count ?? 0)
    }

    private mutating func makeRoom(for entry: ComposerSendRecoveryEntry) -> Bool {
        let bytes = snapshotBytes(entry.snapshot)
        guard bytes <= Self.maxSnapshotBytes else { return false }
        // Every current state is actionable. Never evict user content just
        // to admit another failure; rejection is the safe outcome.
        guard records.count < Self.maxRecords,
              aggregateBytes() + bytes <= Self.maxSnapshotBytes,
              !exceedsAttachmentReferenceCap(snapshot: entry.snapshot, replacing: nil) else {
            return false
        }
        return true
    }

    private func exceedsAttachmentReferenceCap(
        snapshot: ComposerSendRecoverySnapshot,
        replacing recoveryID: String?
    ) -> Bool {
        var ids = Set<String>()
        for entry in allEntries where entry.recoveryID != recoveryID {
            ids.formUnion(entry.snapshot.attachmentIDs)
        }
        ids.formUnion(snapshot.attachmentIDs)
        return ids.count > Self.maxRetainedAttachmentReferences
    }

    private func aggregateBytes() -> Int {
        records.values.reduce(0) { $0 + snapshotBytes($1.snapshot) }
    }

    private func mergeEchoIDs(_ old: [String], _ new: String?) -> [String] {
        var result = old
        if let new, !result.contains(new) { result.append(new) }
        if result.count > Self.maxPendingEchoIDs {
            result.removeFirst(result.count - Self.maxPendingEchoIDs)
        }
        return result
    }

    private func boundedReason(_ raw: String) -> String {
        var bounded = ""
        var bytes = 0
        for scalar in raw.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= Self.maxReasonBytes else { break }
            bounded.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return bounded
    }

    private func attachmentMetadataMatches(_ snapshot: ComposerSendRecoverySnapshot) -> Bool {
        guard snapshot.attachmentMetadata.allSatisfy({
            !$0.id.isEmpty && !$0.path.isEmpty
        }) else {
            return snapshot.attachmentMetadata.isEmpty
        }
        return Set(snapshot.attachmentMetadata.map(\.id))
            .isSubset(of: Set(snapshot.attachmentIDs))
    }

    private mutating func remove(recoveryID: String) {
        records.removeValue(forKey: recoveryID)
        insertionOrder.removeAll { $0 == recoveryID }
    }
}
