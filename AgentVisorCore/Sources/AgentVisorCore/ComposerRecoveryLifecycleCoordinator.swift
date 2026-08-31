import Foundation

/// The durable, view-independent part of the optimistic composer lifecycle.
/// The AppKit adapter owns image values and actual timers; this value type owns
/// the exact session/generation/echo join and decides which lifecycle event is
/// due. Keeping this transition policy in Core makes view destruction and
/// reattachment observable in executable tests.
public struct ComposerRecoveryLifecycleCoordinator: Sendable {
    public struct PendingEcho: Equatable, Sendable {
        public let sessionID: String
        public let generationID: String
        public let echoID: String
        public let deliveryID: String?
        public let expiresAt: Date

        public init(
            sessionID: String,
            generationID: String,
            echoID: String,
            deliveryID: String?,
            expiresAt: Date
        ) {
            self.sessionID = sessionID
            self.generationID = generationID
            self.echoID = echoID
            self.deliveryID = deliveryID
            self.expiresAt = expiresAt
        }
    }

    // ponytail: bound the number of lifecycle records to the same 256 echo
    // admission cap as the app store. Rejecting a new record preserves the
    // complete composer draft; silently evicting an actionable echo would
    // make Retry/recovery impossible.
    public static let maxPendingEchoes = 256

    private var pending: [ComposerRecoveryScopeKey: [String: PendingEcho]] = [:]
    private var generationBySession: [String: String] = [:]

    public init() {}

    public var pendingEchoCount: Int {
        pending.values.reduce(0) { $0 + $1.count }
    }

    public func currentGeneration(for sessionID: String) -> String? {
        generationBySession[sessionID]
    }

    /// Registers a pending echo before the mounted view clears its draft.
    /// Duplicate registration is idempotent only when all identity fields
    /// match; an echo collision is rejected without overwriting the first
    /// delivery.
    @discardableResult
    public mutating func register(
        sessionID: String,
        generationID: String,
        echoID: String,
        deliveryID: String? = nil,
        expiresAt: Date
    ) -> Bool {
        guard !sessionID.isEmpty, !generationID.isEmpty, !echoID.isEmpty else {
            return false
        }
        let key = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )
        var scope = pending[key, default: [:]]
        if let existing = scope[echoID] {
            return existing.deliveryID == deliveryID && existing.expiresAt == expiresAt
        }
        guard pendingEchoCount < Self.maxPendingEchoes else { return false }
        scope[echoID] = PendingEcho(
            sessionID: sessionID,
            generationID: generationID,
            echoID: echoID,
            deliveryID: deliveryID,
            expiresAt: expiresAt
        )
        pending[key] = scope
        generationBySession[sessionID] = generationID
        return true
    }

    /// Canonical transcript evidence consumes one exact echo. Replayed pages
    /// return nil after the first consumption, so a view reattachment cannot
    /// consume a second identical delivery.
    @discardableResult
    public mutating func canonical(
        sessionID: String,
        generationID: String? = nil,
        echoID: String
    ) -> PendingEcho? {
        let keys = pending.keys.filter {
            $0.sessionID == sessionID
                && (generationID == nil || $0.generationID == generationID)
        }
        for key in keys {
            guard var scope = pending[key],
                  let echo = scope.removeValue(forKey: echoID) else { continue }
            pending[key] = scope.isEmpty ? nil : scope
            pruneGenerationIfEmpty(sessionID: key.sessionID, generationID: key.generationID)
            return echo
        }
        return nil
    }

    /// Explicitly cancels one exact echo without fabricating a canonical
    /// success event. Used for confirmed cancellation and generation change.
    @discardableResult
    public mutating func cancel(
        sessionID: String,
        generationID: String? = nil,
        echoID: String
    ) -> PendingEcho? {
        canonical(sessionID: sessionID, generationID: generationID, echoID: echoID)
    }

    /// Returns and removes all echoes due at `now`. Tests inject a fake clock;
    /// the AppKit adapter may call this from one bounded scheduler task.
    public mutating func expire(at now: Date) -> [PendingEcho] {
        var expired: [PendingEcho] = []
        for key in pending.keys {
            guard var scope = pending[key] else { continue }
            let dueIDs = scope.values.filter { $0.expiresAt <= now }.map(\.echoID)
            for echoID in dueIDs {
                if let echo = scope.removeValue(forKey: echoID) { expired.append(echo) }
            }
            pending[key] = scope.isEmpty ? nil : scope
            pruneGenerationIfEmpty(sessionID: key.sessionID, generationID: key.generationID)
        }
        return expired.sorted {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            return $0.echoID < $1.echoID
        }
    }

    /// Replaces a provider identity while retiring all pending echoes from
    /// the old target. Recovery snapshots are migrated by the AppKit adapter;
    /// this policy only ensures old echo identities cannot later confirm the
    /// new generation.
    @discardableResult
    public mutating func replaceGeneration(
        sessionID: String,
        from oldGenerationID: String,
        to newGenerationID: String
    ) -> [PendingEcho] {
        let oldKey = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: oldGenerationID
        )
        let retired: [PendingEcho] = pending.removeValue(forKey: oldKey)
            .map { Array($0.values) } ?? []
        generationBySession[sessionID] = newGenerationID
        return retired
    }

    /// Repository removal clears every generation for one session only.
    @discardableResult
    public mutating func forget(sessionID: String) -> [PendingEcho] {
        let keys = pending.keys.filter { $0.sessionID == sessionID }
        var removed: [PendingEcho] = []
        for key in keys {
            if let scope = pending.removeValue(forKey: key) {
                removed.append(contentsOf: scope.values)
            }
        }
        generationBySession.removeValue(forKey: sessionID)
        return removed
    }

    @discardableResult
    public mutating func forget(
        sessionID: String,
        generationID: String
    ) -> [PendingEcho] {
        let key = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )
        let removed: [PendingEcho] = pending.removeValue(forKey: key)
            .map { Array($0.values) } ?? []
        if generationBySession[sessionID] == generationID {
            generationBySession.removeValue(forKey: sessionID)
        }
        return removed
    }

    /// View destruction never calls this. It is only a deterministic
    /// service-level cleanup helper for tests and empty-scope pruning.
    public func pendingEchoes(
        sessionID: String,
        generationID: String
    ) -> [PendingEcho] {
        pending[ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )].map { Array($0.values) } ?? []
    }

    private mutating func pruneGenerationIfEmpty(
        sessionID: String,
        generationID: String
    ) {
        let key = ComposerRecoveryScopeKey(
            sessionID: sessionID,
            generationID: generationID
        )
        guard pending[key] == nil,
              generationBySession[sessionID] == generationID else { return }
        generationBySession.removeValue(forKey: sessionID)
    }
}
