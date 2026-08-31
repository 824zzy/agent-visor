import Foundation

/// Owns admission for the app bridge's per-session pending-echo scopes.
///
/// The AppKit bridge keeps several dictionaries for one scope (canonical
/// replay IDs, fallback state, echo rows, and attachment/delivery metadata).
/// Admission must happen before any of those dictionaries are mutated so a
/// full table cannot leave a partially-created session behind.
public struct PendingEchoScopeAdmissionPolicy: Sendable {
    // ponytail: keep this coordinated with PendingEchoStore's lifecycle and
    // ComposerRecoveryScopeLedger limits. A new persistent scope is rejected
    // at 32 until the owner explicitly forgets one; never evict actionable
    // echo/recovery content just to make room.
    public static let maxScopes = 32

    private var insertionOrder: [String] = []

    public init() {}

    public var count: Int { insertionOrder.count }

    public func contains(_ sessionID: String) -> Bool {
        insertionOrder.contains(sessionID)
    }

    /// Admit one exact session scope. Re-admission is idempotent; a new scope
    /// is rejected when the bound is full and no state is evicted.
    @discardableResult
    public mutating func admit(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        if contains(sessionID) { return true }
        guard insertionOrder.count < Self.maxScopes else { return false }
        insertionOrder.append(sessionID)
        return true
    }

    /// Forget is the only normal way to release a scope. The app bridge calls
    /// this together with cleanup of every scope-keyed side map and timer.
    @discardableResult
    public mutating func forget(_ sessionID: String) -> Bool {
        let oldCount = insertionOrder.count
        insertionOrder.removeAll { $0 == sessionID }
        return insertionOrder.count != oldCount
    }
}
