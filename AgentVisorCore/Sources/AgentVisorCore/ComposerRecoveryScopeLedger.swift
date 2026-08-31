import Foundation

/// Exact owner key for provider recovery state.  A generation turnover is a
/// new provider identity even when the visible session id is unchanged.
public struct ComposerRecoveryScopeKey: Hashable, Sendable, Equatable {
    public let sessionID: String
    public let generationID: String

    public init(sessionID: String, generationID: String) {
        self.sessionID = sessionID
        self.generationID = generationID
    }
}

/// Core lifecycle policy for app-level recovery scopes.
///
/// This value type deliberately contains no AppKit values.  The app adapter
/// stores image snapshots beside the exact key and is required to remove
/// those values only for IDs returned by these transitions.  Keeping this
/// policy executable in Core makes view destruction/recreation and A→B→A
/// behavior testable without a SwiftUI runtime.
public struct ComposerRecoveryScopeLedger: Sendable {
    // ponytail: bound independently retained session generations at 32.  A
    // new scope is rejected rather than silently evicting actionable content;
    // raise only with durable storage and visible recovery guidance.
    public static let maxScopes = 32

    private var ledgers: [ComposerRecoveryScopeKey: ComposerSendRecoveryLedger] = [:]
    private var insertionOrder: [ComposerRecoveryScopeKey] = []
    private var generationBySession: [String: String] = [:]

    public init() {}

    public func containsScope(_ key: ComposerRecoveryScopeKey) -> Bool {
        ledgers[key] != nil
    }

    public func canEnsureScope(_ key: ComposerRecoveryScopeKey) -> Bool {
        containsScope(key) || insertionOrder.count < Self.maxScopes
    }

    /// Returns the current authoritative generation without creating one.
    /// Mounted views use this read-only query so rendering cannot silently
    /// become the owner of provider-generation lifecycle.
    public func currentGeneration(for sessionID: String) -> String? {
        generationBySession[sessionID]
    }

    /// Stable app-lifetime generation for a session.  Repository replacement
    /// should use `replaceGeneration` when it has an authoritative new id.
    public mutating func generation(for sessionID: String) -> String {
        if let existing = generationBySession[sessionID] {
            return existing
        }
        let value = UUID().uuidString
        generationBySession[sessionID] = value
        return value
    }

    @discardableResult
    public mutating func ensureScope(_ key: ComposerRecoveryScopeKey) -> Bool {
        if ledgers[key] != nil { return true }
        guard insertionOrder.count < Self.maxScopes else { return false }
        ledgers[key] = ComposerSendRecoveryLedger()
        insertionOrder.append(key)
        return true
    }

    public func entries(for key: ComposerRecoveryScopeKey) -> [ComposerSendRecoveryEntry] {
        ledgers[key]?.entries(sessionID: key.sessionID, generationID: key.generationID) ?? []
    }

    public func entry(
        recoveryID: String,
        in key: ComposerRecoveryScopeKey
    ) -> ComposerSendRecoveryEntry? {
        ledgers[key]?.entry(recoveryID: recoveryID)
    }

    public var allEntries: [ComposerSendRecoveryEntry] {
        insertionOrder.flatMap { ledgers[$0]?.allEntries ?? [] }
    }

    public var retainedAttachmentIDs: Set<String> {
        Set(allEntries.flatMap { $0.snapshot.attachmentIDs })
    }

    /// Rebinds recoverable content to a replacement provider generation. The
    /// submitted text/attachments remain byte-for-byte identical, while the
    /// old optimistic echo is intentionally removed: an echo from the prior
    /// provider process can never confirm or retry against the replacement.
    /// The app adapter uses this pure value before retaining its AppKit image
    /// snapshot, so generation migration is executable without SwiftUI.
    public static func restorableSnapshotForGeneration(
        _ snapshot: ComposerSendRecoverySnapshot,
        generationID: String
    ) -> ComposerSendRecoverySnapshot? {
        guard !generationID.isEmpty else { return nil }
        return ComposerSendRecoverySnapshot(
            deliveryID: snapshot.deliveryID,
            sessionID: snapshot.sessionID,
            generationID: generationID,
            text: snapshot.text,
            attachmentIDs: snapshot.attachmentIDs,
            attachmentMetadata: snapshot.attachmentMetadata,
            pendingEchoID: nil,
            submittedRevision: snapshot.submittedRevision,
            clearedRevision: snapshot.clearedRevision
        )
    }

    @discardableResult
    public mutating func admitFailure(
        _ snapshot: ComposerSendRecoverySnapshot,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        let key = ComposerRecoveryScopeKey(
            sessionID: snapshot.sessionID,
            generationID: snapshot.generationID
        )
        guard ensureScope(key) else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        return ledgers[key]?.admitFailure(snapshot: snapshot, reason: reason)
            ?? .rejected(reason: "Recovery is unavailable. Your submitted message remains in the composer.")
    }

    @discardableResult
    public mutating func recordUncertain(
        _ snapshot: ComposerSendRecoverySnapshot,
        reason: String
    ) -> ComposerSendRecoveryAdmission {
        let key = ComposerRecoveryScopeKey(
            sessionID: snapshot.sessionID,
            generationID: snapshot.generationID
        )
        guard ensureScope(key) else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        guard ledgers[key]?.recordUncertain(snapshot: snapshot, reason: reason) == true else {
            return .rejected(reason: "Recovery is full. Your submitted message remains in the composer.")
        }
        return .retained
    }

    /// Records expiry for one exact current pending echo without admitting a
    /// second recovery identity for a retry replacement delivery.
    @discardableResult
    public mutating func recordFailureForPendingEcho(
        _ snapshot: ComposerSendRecoverySnapshot,
        pendingEchoID: String,
        reason: String,
        in key: ComposerRecoveryScopeKey
    ) -> ComposerSendRecoveryAdmission {
        guard snapshot.sessionID == key.sessionID,
              snapshot.generationID == key.generationID,
              ledgers[key]?.recordFailureForPendingEcho(
                  snapshot: snapshot,
                  pendingEchoID: pendingEchoID,
                  reason: reason
              ) == true else {
            return .rejected(reason: "The pending echo no longer owns this recovery entry.")
        }
        return .retained
    }

    /// Starts a retry in one exact scope. The Core ledger retains the old
    /// recovery card if replacement admission fails.
    @discardableResult
    public mutating func beginRetry(
        recoveryID: String,
        replacement: ComposerSendRecoverySnapshot,
        in key: ComposerRecoveryScopeKey,
        allowUncertain: Bool = false
    ) -> ComposerSendRecoveryRetry? {
        guard replacement.sessionID == key.sessionID,
              replacement.generationID == key.generationID,
              ledgers[key] != nil else { return nil }
        return ledgers[key]?.beginRetry(
            recoveryID: recoveryID,
            sessionID: key.sessionID,
            generationID: key.generationID,
            replacement: replacement,
            allowUncertain: allowUncertain
        )
    }

    @discardableResult
    public mutating func finishRetry(
        recoveryID: String,
        deliveryID: String,
        succeeded: Bool,
        reason: String = "Send failed",
        in key: ComposerRecoveryScopeKey
    ) -> Bool {
        ledgers[key]?.finishRetry(
            recoveryID: recoveryID,
            deliveryID: deliveryID,
            succeeded: succeeded,
            reason: reason
        ) ?? false
    }

    /// Atomically transitions a retry to uncertain without a second admission
    /// keyed by the replacement delivery ID. The caller can then dismiss or
    /// explicitly risk-retry the one surviving recovery card.
    @discardableResult
    public mutating func finishRetryUncertain(
        recoveryID: String,
        deliveryID: String,
        reason: String,
        in key: ComposerRecoveryScopeKey
    ) -> Bool {
        ledgers[key]?.finishRetryUncertain(
            recoveryID: recoveryID,
            deliveryID: deliveryID,
            reason: reason
        ) ?? false
    }

    @discardableResult
    public mutating func dismiss(
        recoveryID: String,
        in key: ComposerRecoveryScopeKey
    ) -> Bool {
        ledgers[key]?.dismiss(
            recoveryID: recoveryID,
            sessionID: key.sessionID,
            generationID: key.generationID
        ) ?? false
    }

    @discardableResult
    public mutating func reconcileCanonical(
        pendingEchoID: String,
        in key: ComposerRecoveryScopeKey
    ) -> [String] {
        ledgers[key]?.reconcileCanonical(
            sessionID: key.sessionID,
            generationID: key.generationID,
            pendingEchoID: pendingEchoID
        ) ?? []
    }

    /// Explicit repository removal returns the exact records whose app-side
    /// attachment snapshots must be released.  Other scopes are untouched.
    @discardableResult
    public mutating func forget(_ key: ComposerRecoveryScopeKey) -> [ComposerSendRecoveryEntry] {
        let entries = ledgers.removeValue(forKey: key)?.allEntries ?? []
        insertionOrder.removeAll { $0 == key }
        if generationBySession[key.sessionID] == key.generationID {
            generationBySession.removeValue(forKey: key.sessionID)
        }
        return entries
    }

    /// Explicitly removes every generation owned by one repository session.
    /// This is the only safe operation for session deletion/pruning: a
    /// generation-specific forget would leave an older provider identity (or
    /// its generation mapping) available for a later session-id reuse.
    @discardableResult
    public mutating func forget(sessionID: String) -> [ComposerSendRecoveryEntry] {
        let keys = insertionOrder.filter { $0.sessionID == sessionID }
        var entries: [ComposerSendRecoveryEntry] = []
        for key in keys {
            entries.append(contentsOf: forget(key))
        }
        generationBySession.removeValue(forKey: sessionID)
        return entries
    }

    /// Replaces one provider generation without retrying stale identities.
    /// The old entries are returned so the app can present/restores them as a
    /// fail-safe before it releases their files.
    @discardableResult
    public mutating func replaceGeneration(
        sessionID: String,
        from oldGenerationID: String,
        to newGenerationID: String
    ) -> [ComposerSendRecoveryEntry] {
        let oldKey = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: oldGenerationID
        )
        let oldEntries = forget(oldKey)
        let newKey = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: newGenerationID
        )
        generationBySession[sessionID] = newGenerationID
        _ = ensureScope(newKey)
        return oldEntries
    }
}
