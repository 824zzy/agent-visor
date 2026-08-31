//
//  PendingEchoStore.swift
//  AgentVisor
//
//  Per-session pending-echo store for window-mode optimistic local
//  echo. The composer pushes the user's text into this store the
//  moment they hit Return; `WindowChatViewModel` merges echoes into
//  the rendered timeline so the message shows up instantly instead
//  of waiting 1-2 s for JSONL to sync.
//
//  Eviction sources:
//      • Reconcile: when JSONL syncs, matching real user turns evict
//        their corresponding echoes (text-match, trimmed).
//      • TTL backstop: 30 s, in case the message never landed. The timer is
//        owned by ComposerRecoveryScopeStore so it survives view destruction.
//      • evict(sessionId:id:): called by ESC-cancel for the exact submitted
//        delivery. Other sends in the same session remain visible.
//
//  Pure dict-mutation logic lives in `AgentVisorCore.PendingEchoLogic`
//  with TDD-covered tests; this class wraps that with @Published +
//  the TTL Task lifecycle and the bridge between [ChatHistoryItem]
//  (the renderer's row type) and [PendingEchoItem] (the Core type).
//

import AgentVisorCore
import Combine
import Foundation

@MainActor
final class PendingEchoStore: ObservableObject {
    static let shared = PendingEchoStore()

    /// Per-session list of pending user-message echoes. Public for
    /// view-model merge via Combine.
    @Published private(set) var echoesBySession: [String: [ChatHistoryItem]] = [:]

    // ponytail: keep this bounded to the newest canonical IDs if a session's
    // history can exceed the renderer's normal transcript window.
    private static let maxSeenCanonicalIDs = 512
    // ponytail: cap optimistic rows per session; if more are needed, add a
    // durable delivery cursor before increasing this UI-memory bound.
    private static let maxEchoesPerSession = 256

    /// Canonical IDs already considered by reconciliation, per session.
    /// This prevents a replayed transcript page from consuming another
    /// identical optimistic echo.
    private var seenCanonicalIDsBySession: [String: [String]] = [:]
    /// Image references are not part of ChatHistoryItem's user-row payload,
    /// so retain them by exact synthetic echo ID for content-aware matching.
    /// This map is bounded and removed synchronously with its echo.
    private var imageReferencesByEchoID: [String: [String]] = [:]
    /// The sender's delivery identity is the only content-independent join
    /// available to this thin app bridge. Keep it alongside the image map so
    /// a provider row can reconcile without a fabricated timestamp.
    private var deliveryIDsByEchoID: [String: String] = [:]
    private var observedCanonicalSessions: Set<String> = []
    private var contentFallbackEnabledBySession: [String: Bool] = [:]
    /// One admission token covers every app-side map for a session. The token
    /// is acquired before any map/timer mutation and released only by
    /// `forget`, so a full table cannot leave partial scope state behind.
    private var scopeAdmission = PendingEchoScopeAdmissionPolicy()

    private init() {}

    /// Push a user-message echo for `sessionId`. The `id` uses an
    /// `echo:` prefix so the merge logic in WindowChatViewModel can
    /// distinguish synthetic echoes from real JSONL ids.
    @discardableResult
    func push(
        sessionId: String,
        text: String,
        imageReferences: [String] = [],
        generationID: String? = nil,
        deliveryID: String? = nil,
        submittedAt: Date = Date()
    ) -> String? {
        let alreadyAdmitted = scopeAdmission.contains(sessionId)
        guard scopeAdmission.admit(sessionId) else {
            // Refuse admission rather than evicting an inactive session's
            // recoverable echo. The composer keeps the complete draft.
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = imageReferences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty || !references.isEmpty else {
            if !alreadyAdmitted { _ = scopeAdmission.forget(sessionId) }
            return nil
        }
        guard echoesBySession[sessionId, default: []].count < Self.maxEchoesPerSession else {
            // Never evict an actionable optimistic row to admit another one.
            // The composer treats nil as a send admission failure and keeps
            // the full draft visible.
            if !alreadyAdmitted { _ = scopeAdmission.forget(sessionId) }
            return nil
        }
        // Keep an image-only optimistic turn visible in the existing
        // transcript row model. The display placeholder is stripped by the
        // Core matcher; image references remain the content identity.
        let displayText = text.isEmpty ? "[Image]" : text
        let item = ChatHistoryItem(
            id: "echo:\(sessionId):\(UUID().uuidString)",
            type: .user(displayText),
            timestamp: submittedAt
        )
        // Validate the push via Core logic (handles empty/whitespace
        // text), then mirror the resulting set of echo IDs into the
        // ChatHistoryItem-typed storage. The Core type doesn't carry
        // ChatHistoryItem (Core can't import the main-app type), so
        // we keep both representations in sync via this thin bridge.
        let projection = projectionsForCore()
        let nextProjection = PendingEchoLogic.push(
            into: projection,
            sessionId: sessionId,
            id: item.id,
            text: text,
            imageReferences: references,
            submittedAt: submittedAt,
            deliveryID: deliveryID
        )
        guard nextProjection[sessionId]?.contains(where: { $0.id == item.id }) == true else {
            if !alreadyAdmitted { _ = scopeAdmission.forget(sessionId) }
            return nil  // PendingEchoLogic.push rejected (empty/whitespace).
        }

        // Register the lifecycle record before publishing any echo metadata.
        // If the bounded lifecycle coordinator is full, this scope admission
        // is rolled back and no side map retains a half-created submission.
        guard ComposerRecoveryScopeStore.shared.schedulePendingEchoExpiry(
            sessionID: sessionId,
            echoID: item.id,
            generationID: generationID,
            deliveryID: deliveryID
        ) else {
            if !alreadyAdmitted { _ = scopeAdmission.forget(sessionId) }
            return nil
        }
        var echoes = echoesBySession[sessionId, default: []]
        echoes.append(item)
        echoesBySession[sessionId] = echoes
        if !references.isEmpty {
            imageReferencesByEchoID[item.id] = references
        }
        if let deliveryID, !deliveryID.isEmpty {
            deliveryIDsByEchoID[item.id] = deliveryID
        }

        return item.id
    }

    /// Reconcile: when JSONL syncs, the real user turn appears in
    /// `realItems`. Drop any pending echo whose trimmed text matches
    /// a recent real user message.
    func reconcile(
        sessionId: String,
        realItems: [ChatHistoryItem],
        authoritativeLatest: Bool = true,
        baselineComplete: Bool = true
    ) -> Bool {
        guard scopeAdmission.admit(sessionId) else { return false }
        let hasObservedBaseline = observedCanonicalSessions.contains(sessionId)
        if authoritativeLatest && baselineComplete {
            // A pre-load pulse may have seeded an incomplete baseline. Once
            // the authoritative latest page arrives, content fallback becomes
            // eligible only after the Core seam has matched its new rows.
            contentFallbackEnabledBySession[sessionId] = true
        }
        if !hasObservedBaseline && (!authoritativeLatest || !baselineComplete) {
            // A first page can race the send. Treat it as the baseline rather
            // than proof of a newly delivered turn, so late initial history
            // cannot consume an identical image-only echo.
            observeCanonical(
                sessionId: sessionId,
                realItems: realItems,
                authoritativeLatest: authoritativeLatest,
                baselineComplete: baselineComplete
            )
            return true
        }
        let recentUserItems: [PendingEchoCanonicalItem] = realItems
            .compactMap { item -> PendingEchoCanonicalItem? in
                switch item.type {
                case .user(let text):
                    return PendingEchoCanonicalItem(
                        id: item.id,
                        text: text,
                        occurredAt: trustedOccurrenceDate(item.timestamp)
                    )
                case .image(let image):
                    return PendingEchoCanonicalItem(
                        id: item.id,
                        text: "",
                        imageReferences: [image.value],
                        occurredAt: trustedOccurrenceDate(item.timestamp)
                    )
                default:
                    return nil
                }
            }
            .suffix(10)
        let projection = projectionsForCore()
        var seenCanonicalIDs = seenCanonicalIDsBySession[sessionId] ?? []
        let nextProjection = PendingEchoLogic.reconcileAuthoritativeLatest(
            projection,
            sessionId: sessionId,
            realUserItems: recentUserItems,
            seenCanonicalIDs: &seenCanonicalIDs,
            maxSeenCanonicalIDs: Self.maxSeenCanonicalIDs,
            context: PendingEchoReconciliationContext(
                authoritativeLatest: authoritativeLatest && contentFallbackEnabledBySession[sessionId] == true,
                baselineComplete: baselineComplete && contentFallbackEnabledBySession[sessionId] == true
            )
        )
        // Keep the insertion-ordered replay window across page refreshes.
        // Replacing it with the current page would let an older replayed
        // page consume a second identical pending echo.
        seenCanonicalIDsBySession[sessionId] = seenCanonicalIDs
        let removed = applyProjection(nextProjection, sessionId: sessionId)
        for echoID in removed {
            ComposerRecoveryScopeStore.shared.handlePendingEchoLifecycle(
                sessionID: sessionId,
                echoID: echoID,
                reason: "canonical"
            )
        }
        return true
    }

    /// Seed the canonical replay window without consuming echoes. This is
    /// used for the first authoritative history observation, which can race a
    /// send while the file is loading; old identical prompts must remain a
    /// baseline rather than confirming the new delivery by text alone.
    func observeCanonical(
        sessionId: String,
        realItems: [ChatHistoryItem],
        authoritativeLatest: Bool = false,
        baselineComplete: Bool = false
    ) -> Bool {
        guard scopeAdmission.admit(sessionId) else { return false }
        observedCanonicalSessions.insert(sessionId)
        contentFallbackEnabledBySession[sessionId] = authoritativeLatest && baselineComplete
        let recentUserItems: [PendingEchoCanonicalItem] = realItems
            .compactMap { item -> PendingEchoCanonicalItem? in
                switch item.type {
                case .user(let text):
                    return PendingEchoCanonicalItem(
                        id: item.id,
                        text: text,
                        occurredAt: trustedOccurrenceDate(item.timestamp)
                    )
                case .image(let image):
                    return PendingEchoCanonicalItem(
                        id: item.id,
                        text: "",
                        imageReferences: [image.value],
                        occurredAt: trustedOccurrenceDate(item.timestamp)
                    )
                default:
                    return nil
                }
            }
            .suffix(10)
        var seenCanonicalIDs = seenCanonicalIDsBySession[sessionId] ?? []
        PendingEchoLogic.rememberCanonicalIDs(
            recentUserItems,
            seenCanonicalIDs: &seenCanonicalIDs,
            maxSeenCanonicalIDs: Self.maxSeenCanonicalIDs
        )
        seenCanonicalIDsBySession[sessionId] = seenCanonicalIDs
        return true
    }

    /// Evict one exact submitted echo. Cancellation must not remove other
    /// pending deliveries from the same session.
    func evict(sessionId: String, id: String, reason: String = "expiry-or-targeted-eviction") {
        let projection = projectionsForCore()
        let nextProjection = PendingEchoLogic.evict(
            from: projection,
            sessionId: sessionId,
            id: id
        )
        let removed = applyProjection(nextProjection, sessionId: sessionId)
        guard removed.contains(id) else { return }
        ComposerRecoveryScopeStore.shared.handlePendingEchoLifecycle(
            sessionID: sessionId,
            echoID: id,
            reason: reason
        )
    }

    func contains(sessionId: String, id: String) -> Bool {
        echoesBySession[sessionId]?.contains(where: { $0.id == id }) == true
    }

    /// Admission check used before the composer clears a draft. The caller
    /// must not submit when the bounded optimistic ledger cannot retain a
    /// visible row for a possible failure.
    func canAccept(sessionId: String) -> Bool {
        canRetainSessionScope(sessionId)
            && echoesBySession[sessionId, default: []].count < Self.maxEchoesPerSession
    }

    /// Explicit lifecycle hook for a session that the repository removed.
    /// Switching views does not call this, so recoverable content survives an
    /// away/back navigation; only authoritative removal releases its scope.
    func forget(sessionId: String) {
        let prefix = "echo:\(sessionId):"
        let echoIDs = echoesBySession[sessionId, default: []].map(\.id)
        let imageIDs = imageReferencesByEchoID.keys.filter { $0.hasPrefix(prefix) }
        let deliveryIDs = deliveryIDsByEchoID.keys.filter { $0.hasPrefix(prefix) }
        let hadState = scopeAdmission.contains(sessionId)
            || seenCanonicalIDsBySession[sessionId] != nil
            || echoesBySession[sessionId] != nil
            || observedCanonicalSessions.contains(sessionId)
            || !imageIDs.isEmpty
            || !deliveryIDs.isEmpty

        // Clear task/lifecycle state even when the corresponding echo row was
        // already removed (for example after an app-side recovery transition).
        ComposerRecoveryScopeStore.shared.forgetPendingEchoes(sessionID: sessionId)
        _ = scopeAdmission.forget(sessionId)
        seenCanonicalIDsBySession.removeValue(forKey: sessionId)
        echoesBySession.removeValue(forKey: sessionId)
        observedCanonicalSessions.remove(sessionId)
        contentFallbackEnabledBySession.removeValue(forKey: sessionId)
        for echoID in imageIDs {
            imageReferencesByEchoID.removeValue(forKey: echoID)
        }
        for echoID in deliveryIDs {
            deliveryIDsByEchoID.removeValue(forKey: echoID)
        }
        if hadState || !imageIDs.isEmpty {
            objectWillChange.send()
        }
    }

    private func canRetainSessionScope(_ sessionId: String) -> Bool {
        scopeAdmission.contains(sessionId)
            || scopeAdmission.count < PendingEchoScopeAdmissionPolicy.maxScopes
    }

    /// Conversation parsers historically required a non-optional display
    /// date. `distantPast` is the explicit no-source-time sentinel used by
    /// the parser; never treat it as a trustworthy occurrence boundary.
    private func trustedOccurrenceDate(_ timestamp: Date) -> Date? {
        timestamp == .distantPast || timestamp == Date(timeIntervalSince1970: 0)
            ? nil
            : timestamp
    }

    // MARK: - Bridge to Core

    /// Project the `ChatHistoryItem`-typed storage into Core's
    /// `PendingEchoItem` shape so we can call into `PendingEchoLogic`.
    private func projectionsForCore() -> [String: [PendingEchoItem]] {
        var out: [String: [PendingEchoItem]] = [:]
        for (key, items) in echoesBySession {
            out[key] = items.map { item in
                let text: String
                if case .user(let t) = item.type { text = t } else { text = "" }
                return PendingEchoItem(
                    id: item.id,
                    text: text,
                    imageReferences: imageReferencesByEchoID[item.id] ?? [],
                    submittedAt: item.timestamp,
                    deliveryID: deliveryIDsByEchoID[item.id]
                )
            }
        }
        return out
    }

    /// Mirror a Core decision back into the ChatHistoryItem-typed
    /// storage by keeping ChatHistoryItems whose ids survived in the
    /// new projection. Scoped to the affected session for fewer
    /// allocations on the hot reconcile path.
    @discardableResult
    private func applyProjection(
        _ projection: [String: [PendingEchoItem]],
        sessionId: String
    ) -> Set<String> {
        let previousIds = Set(echoesBySession[sessionId, default: []].map(\.id))
        let survivingIds = Set((projection[sessionId] ?? []).map(\.id))
        if survivingIds.isEmpty {
            if echoesBySession[sessionId] != nil {
                echoesBySession.removeValue(forKey: sessionId)
            }
        } else if let current = echoesBySession[sessionId] {
            let filtered = current.filter { survivingIds.contains($0.id) }
            if filtered.count != current.count {
                echoesBySession[sessionId] = filtered
            }
        }
        let removedIds = previousIds.subtracting(survivingIds)
        for id in removedIds {
            imageReferencesByEchoID.removeValue(forKey: id)
            deliveryIDsByEchoID.removeValue(forKey: id)
        }
        return removedIds
    }
}
