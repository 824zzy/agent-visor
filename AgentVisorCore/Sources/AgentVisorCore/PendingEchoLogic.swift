//
//  PendingEchoLogic.swift
//  AgentVisorCore
//
//  Pure dictionary-mutation logic for the window-mode optimistic
//  echo store. The main-app `PendingEchoStore` owns @Published state +
//  Combine wiring; this Core type owns WHAT-changes decisions so they
//  can be unit-tested without mocking SwiftUI.
//
//  Operations:
//      • push: append a pending echo for a session (no-op on
//        empty/whitespace text).
//      • evict(by id): remove the one echo belonging to a submitted
//        delivery. Cancellation must use this identity, never clear a
//        different in-flight send from the same session.
//      • reconcile: text-match echoes against the newest real user
//        turns from JSONL; matching echoes evict.
//

import Foundation

/// Lightweight, type-erased echo entry. PendingEchoStore wraps each
/// real `ChatHistoryItem` echo into one of these so Core stays free
/// of main-app types.
public struct PendingEchoItem: Equatable, Sendable {
    public let id: String
    /// Monotonic submission boundary used to reject an older canonical row
    /// that only becomes visible after an incomplete/empty initial page.
    public let submittedAt: Date
    /// Provider delivery identity, when the sender has one. This is allowed
    /// to reconcile even if the provider omitted an occurrence timestamp.
    public let deliveryID: String?
    public let text: String
    /// Provider-visible image references for this submitted turn. Image-only
    /// turns have no meaningful text, so their content identity must not be
    /// reduced to a display placeholder such as "[Image]".
    public let imageReferences: [String]

    public init(
        id: String,
        text: String,
        imageReferences: [String] = [],
        submittedAt: Date = .distantPast,
        deliveryID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.imageReferences = imageReferences
        self.submittedAt = submittedAt
        self.deliveryID = deliveryID
    }
}

/// A canonical transcript user turn with a stable provider/parser identity.
/// The identity lets the store distinguish a replayed page from a newly
/// appended turn when two messages have identical text.
public struct PendingEchoCanonicalItem: Equatable, Sendable {
    public let id: String
    public let text: String
    /// Source occurrence time. `nil` means the parser did not observe a
    /// trustworthy provider timestamp; it must not be fabricated at render
    /// time for content-only matching.
    public let occurredAt: Date?
    /// Provider delivery identity, when the transcript exposes it.
    public let deliveryID: String?
    /// Canonical image paths/data identities when the provider exposes them.
    /// An empty text plus non-empty references is an image-only canonical row.
    public let imageReferences: [String]

    public init(
        id: String,
        text: String,
        imageReferences: [String] = [],
        occurredAt: Date? = nil,
        deliveryID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.imageReferences = imageReferences
        self.occurredAt = occurredAt
        self.deliveryID = deliveryID
    }
}

/// Evidence required before content-only reconciliation is allowed. Exact
/// provider delivery identity remains valid even when this context is false.
public struct PendingEchoReconciliationContext: Equatable, Sendable {
    public let authoritativeLatest: Bool
    public let baselineComplete: Bool

    public init(authoritativeLatest: Bool, baselineComplete: Bool) {
        self.authoritativeLatest = authoritativeLatest
        self.baselineComplete = baselineComplete
    }
}

public enum PendingEchoLogic {
    /// Record canonical identities without consuming any pending echoes.
    ///
    /// The window view calls this for the first authoritative history
    /// observation. A send can race initial file loading; treating that first
    /// page as a baseline prevents an old identical prompt from consuming the
    /// new optimistic echo. Later pages use `reconcileIdentified` so only
    /// canonical IDs first observed after the baseline can consume an echo.
    public static func rememberCanonicalIDs(
        _ realUserItems: [PendingEchoCanonicalItem],
        seenCanonicalIDs: inout [String],
        maxSeenCanonicalIDs: Int = 512
    ) {
        // ponytail: bound this replay history to the newest canonical IDs;
        // raising the default requires reviewing transcript replay memory.
        let cap = max(0, maxSeenCanonicalIDs)
        var orderedIDs: [String] = []
        var seen = Set<String>()
        for id in seenCanonicalIDs where !id.isEmpty && seen.insert(id).inserted {
            orderedIDs.append(id)
        }
        for item in realUserItems where !item.id.isEmpty && seen.insert(item.id).inserted {
            orderedIDs.append(item.id)
        }
        if orderedIDs.count > cap {
            orderedIDs.removeFirst(orderedIDs.count - cap)
        }
        seenCanonicalIDs = orderedIDs
    }

    /// Append an echo to `state[sessionId]`. Empty / whitespace-only
    /// text is a no-op (the user hit Enter on a blank composer; we
    /// don't want a phantom empty bubble).
    public static func push(
        into state: [String: [PendingEchoItem]],
        sessionId: String,
        id: String,
        text: String,
        imageReferences: [String] = [],
        submittedAt: Date = .distantPast,
        deliveryID: String? = nil
    ) -> [String: [PendingEchoItem]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = imageReferences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Image-only submissions have no user text but still need a visible,
        // identity-bearing optimistic row for reconciliation and recovery.
        guard !trimmed.isEmpty || !references.isEmpty else { return state }
        var next = state
        next[sessionId, default: []].append(PendingEchoItem(
            id: id,
            text: text,
            imageReferences: references,
            submittedAt: submittedAt,
            deliveryID: deliveryID
        ))
        return next
    }

    /// Remove a single echo by id. If the session's list goes empty,
    /// drop the dictionary entry entirely so reconcile/merge code can
    /// branch on `state[sessionId] == nil` without checking emptiness.
    public static func evict(
        from state: [String: [PendingEchoItem]],
        sessionId: String,
        id: String
    ) -> [String: [PendingEchoItem]] {
        guard var list = state[sessionId] else { return state }
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return state }
        var next = state
        if list.isEmpty {
            next.removeValue(forKey: sessionId)
        } else {
            next[sessionId] = list
        }
        return next
    }

    /// Remove echoes whose normalized text matches any item in
    /// `realUserTexts`. Both sides are trimmed AND have any leading
    /// `[Image]` / `[Image #N]` placeholder tokens stripped before
    /// comparison — Claude Code's TUI rewrites the user turn in JSONL
    /// with `[Image #N]` prefixes when images are attached, while the
    /// optimistic echo carries only the typed text. Without this
    /// normalization the echo lingers until the 30 s TTL backstop
    /// (visible as "the same message shows twice; bottom one
    /// disappears later").
    public static func reconcile(
        _ state: [String: [PendingEchoItem]],
        sessionId: String,
        realUserTexts: [String]
    ) -> [String: [PendingEchoItem]] {
        guard let pending = state[sessionId], !pending.isEmpty else { return state }
        // Consume each canonical text once. A Set incorrectly removes every
        // identical pending echo when a transcript contains only one such
        // turn; this multiset preserves the second optimistic submission.
        var remainingMatches: [String: Int] = [:]
        for text in realUserTexts {
            let key = normalizeForReconcile(text)
            guard !key.isEmpty else { continue }
            remainingMatches[key, default: 0] += 1
        }
        let kept = pending.filter { echo in
            // This legacy text-only seam cannot prove an image-aware echo.
            // Keep it until the canonical image-aware seam sees the exact
            // references; never let a placeholder consume it by text alone.
            guard echo.imageReferences.isEmpty else { return true }
            let key = normalizeForReconcile(echo.text)
            guard !key.isEmpty, let count = remainingMatches[key], count > 0 else { return true }
            remainingMatches[key] = count - 1
            return false
        }
        guard kept.count != pending.count else { return state }
        var next = state
        if kept.isEmpty {
            next.removeValue(forKey: sessionId)
        } else {
            next[sessionId] = kept
        }
        return next
    }

    /// Reconcile against canonical turns while suppressing repeated page
    /// deliveries by canonical identity. The caller owns the bounded set of
    /// identities because the Core layer is deliberately stateless.
    public static func reconcileIdentified(
        _ state: [String: [PendingEchoItem]],
        sessionId: String,
        realUserItems: [PendingEchoCanonicalItem],
        seenCanonicalIDs: inout Set<String>,
        context: PendingEchoReconciliationContext = .init(
            authoritativeLatest: true,
            baselineComplete: true
        )
    ) -> [String: [PendingEchoItem]] {
        let unseenItems = realUserItems.filter { seenCanonicalIDs.insert($0.id).inserted }
        guard !unseenItems.isEmpty else { return state }
        return reconcileIdentifiedItems(
            state,
            sessionId: sessionId,
            unseenItems: unseenItems,
            context: context
        )
    }

    /// Reconcile against canonical turns while retaining an insertion-ordered
    /// replay window. This overload is the stateful seam used by the main-app
    /// store; keeping the history here makes the one-to-one identity policy
    /// testable without exposing the store's Combine state.
    public static func reconcileIdentified(
        _ state: [String: [PendingEchoItem]],
        sessionId: String,
        realUserItems: [PendingEchoCanonicalItem],
        seenCanonicalIDs: inout [String],
        maxSeenCanonicalIDs: Int = 512,
        context: PendingEchoReconciliationContext = .init(
            authoritativeLatest: true,
            baselineComplete: true
        )
    ) -> [String: [PendingEchoItem]] {
        reconcileAuthoritativeLatest(
            state,
            sessionId: sessionId,
            realUserItems: realUserItems,
            seenCanonicalIDs: &seenCanonicalIDs,
            maxSeenCanonicalIDs: maxSeenCanonicalIDs,
            context: context
        )
    }

    /// Reconcile an authoritative latest page before adding its remaining
    /// canonical IDs to the replay baseline. A provider may commit a turn
    /// while the view is detached; seeding that first page before matching
    /// would make the new row look like old history and strand the echo.
    ///
    /// Exact provider identity remains valid without timestamps. Content-only
    /// matching is still gated by `context` and each item's source timestamp
    /// in `reconcileIdentifiedItems`.
    public static func reconcileAuthoritativeLatest(
        _ state: [String: [PendingEchoItem]],
        sessionId: String,
        realUserItems: [PendingEchoCanonicalItem],
        seenCanonicalIDs: inout [String],
        maxSeenCanonicalIDs: Int = 512,
        context: PendingEchoReconciliationContext = .init(
            authoritativeLatest: true,
            baselineComplete: true
        )
    ) -> [String: [PendingEchoItem]] {
        var observedIDs = Set(seenCanonicalIDs)
        var unseenItems: [PendingEchoCanonicalItem] = []
        for item in realUserItems where !item.id.isEmpty && observedIDs.insert(item.id).inserted {
            unseenItems.append(item)
        }
        // Matching must happen while the page is still distinguishable from
        // the baseline. Only afterward do we remember every remaining row.
        let reconciled = reconcileIdentifiedItems(
            state,
            sessionId: sessionId,
            unseenItems: unseenItems,
            context: context
        )
        rememberCanonicalIDs(
            realUserItems,
            seenCanonicalIDs: &seenCanonicalIDs,
            maxSeenCanonicalIDs: maxSeenCanonicalIDs
        )
        return reconciled
    }

    private static func reconcileIdentifiedItems(
        _ state: [String: [PendingEchoItem]],
        sessionId: String,
        unseenItems: [PendingEchoCanonicalItem],
        context: PendingEchoReconciliationContext = .init(
            authoritativeLatest: true,
            baselineComplete: true
        )
    ) -> [String: [PendingEchoItem]] {
        guard let pending = state[sessionId], !pending.isEmpty else { return state }
        var remaining = pending
        // Consume each newly observed canonical row at most once. Matching
        // is identity-first for image rows and uses exact normalized text
        // only when the canonical provider does not expose image metadata.
        for canonical in unseenItems {
            guard let index = remaining.firstIndex(where: {
                contentMatches(echo: $0, canonical: canonical, context: context)
            }) else { continue }
            remaining.remove(at: index)
        }
        guard remaining.count != pending.count else { return state }
        var next = state
        if remaining.isEmpty {
            next.removeValue(forKey: sessionId)
        } else {
            next[sessionId] = remaining
        }
        return next
    }

    private static func contentMatches(
        echo: PendingEchoItem,
        canonical: PendingEchoCanonicalItem,
        context: PendingEchoReconciliationContext
    ) -> Bool {
        if let canonicalDeliveryID = canonical.deliveryID {
            // An explicit provider identity is authoritative. Never consume
            // an echo by text or image when the provider identified a
            // different (or otherwise uncorrelatable) delivery.
            guard let echoDeliveryID = echo.deliveryID else { return false }
            return canonicalDeliveryID == echoDeliveryID
        }
        // Keep the original pure text-only helper usable by older callers
        // that construct an echo without a submission boundary. The app
        // store always supplies a real boundary; those records must satisfy
        // the authoritative/latest and occurrence-time checks below.
        if echo.submittedAt != .distantPast {
            guard context.authoritativeLatest,
                  context.baselineComplete,
                  let occurredAt = canonical.occurredAt,
                  occurredAt >= echo.submittedAt else { return false }
        }
        let echoImages = normalizedImageReferences(echo.imageReferences)
        let canonicalImages = normalizedImageReferences(canonical.imageReferences)
        if !canonicalImages.isEmpty {
            guard echoImages == canonicalImages else { return false }
            let echoText = normalizeForReconcile(echo.text)
            let canonicalText = normalizeForReconcile(canonical.text)
            return echoText.isEmpty || canonicalText.isEmpty || echoText == canonicalText
        }
        // A provider may emit a path-bearing prompt as text (Pi). In that
        // case exact canonical text is sufficient because it includes the
        // submitted paths; a generic image placeholder is not.
        guard !echoImages.isEmpty else {
            return normalizeForReconcile(echo.text) == normalizeForReconcile(canonical.text)
                && !normalizeForReconcile(canonical.text).isEmpty
        }
        let echoText = normalizeForReconcile(echo.text)
        let canonicalText = normalizeForReconcile(canonical.text)
        return !echoText.isEmpty && echoText == canonicalText
    }

    private static func normalizedImageReferences(_ references: [String]) -> [String] {
        references.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// Strip leading `[Image]` / `[Image #N]` placeholder tokens
    /// (consecutive, whitespace-separated) and trim. A purely-prefix
    /// string normalizes to "" — the caller filters those out so an
    /// image-only real turn never matches a plain-text echo.
    static func normalizeForReconcile(_ raw: String) -> String {
        var s = Substring(raw)
        s = s.drop(while: { $0.isWhitespace })
        while true {
            guard let after = stripOneImagePrefix(s) else { break }
            s = after.drop(while: { $0.isWhitespace })
        }
        return String(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the remainder after a single leading `[Image]` or
    /// `[Image #N]` token, or nil if no such prefix is at the start.
    private static func stripOneImagePrefix(_ s: Substring) -> Substring? {
        guard s.first == "[" else { return nil }
        var rest = s.dropFirst()
        guard rest.hasPrefix("Image") else { return nil }
        rest = rest.dropFirst("Image".count)
        if rest.first == "]" {
            return rest.dropFirst()
        }
        // Optional whitespace + "#" + digits + "]"
        rest = rest.drop(while: { $0 == " " })
        guard rest.first == "#" else { return nil }
        rest = rest.dropFirst()
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "]" else { return nil }
        return rest.dropFirst()
    }
}
