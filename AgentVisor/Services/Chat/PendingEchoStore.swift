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
//      • TTL backstop: 30 s, in case the message never landed.
//      • evictAll: called by ESC-cancel — the canonical user turn is
//        already in JSONL, so the echo bubble is a duplicate and goes.
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

    /// Hard upper bound — if a real JSONL turn hasn't matched within
    /// this window we evict the echo so it doesn't linger forever.
    private static let echoTTL: TimeInterval = 30

    private init() {}

    /// Push a user-message echo for `sessionId`. The `id` uses an
    /// `echo:` prefix so the merge logic in WindowChatViewModel can
    /// distinguish synthetic echoes from real JSONL ids.
    func push(sessionId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ChatHistoryItem(
            id: "echo:\(sessionId):\(UUID().uuidString)",
            type: .user(text),
            timestamp: Date()
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
            text: text
        )
        guard nextProjection[sessionId]?.contains(where: { $0.id == item.id }) == true else {
            return  // PendingEchoLogic.push rejected (empty/whitespace).
        }
        echoesBySession[sessionId, default: []].append(item)

        // TTL backstop. Capture the id so we only remove THIS echo
        // even if other echoes pile up for the same session.
        let echoId = item.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.echoTTL * 1_000_000_000))
            await MainActor.run {
                self?.evict(sessionId: sessionId, id: echoId)
            }
        }
    }

    /// Reconcile: when JSONL syncs, the real user turn appears in
    /// `realItems`. Drop any pending echo whose trimmed text matches
    /// a recent real user message.
    func reconcile(sessionId: String, realItems: [ChatHistoryItem]) {
        let recentUserTexts: [String] = realItems
            .compactMap { item -> String? in
                guard case .user(let t) = item.type else { return nil }
                return t
            }
            .suffix(10)
        let projection = projectionsForCore()
        let nextProjection = PendingEchoLogic.reconcile(
            projection,
            sessionId: sessionId,
            realUserTexts: recentUserTexts
        )
        applyProjection(nextProjection, sessionId: sessionId)
    }

    /// Evict ALL pending echoes for `sessionId`. Triggered by ESC-
    /// cancel: Claude Code may have already written the user turn to
    /// JSONL before the interrupt, so the canonical row is there;
    /// the optimistic echo bubble would render alongside it as a
    /// duplicate. Drop it.
    func evictAll(sessionId: String) {
        let projection = projectionsForCore()
        let nextProjection = PendingEchoLogic.evictAll(
            from: projection,
            sessionId: sessionId
        )
        applyProjection(nextProjection, sessionId: sessionId)
    }

    private func evict(sessionId: String, id: String) {
        let projection = projectionsForCore()
        let nextProjection = PendingEchoLogic.evict(
            from: projection,
            sessionId: sessionId,
            id: id
        )
        applyProjection(nextProjection, sessionId: sessionId)
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
                return PendingEchoItem(id: item.id, text: text)
            }
        }
        return out
    }

    /// Mirror a Core decision back into the ChatHistoryItem-typed
    /// storage by keeping ChatHistoryItems whose ids survived in the
    /// new projection. Scoped to the affected session for fewer
    /// allocations on the hot reconcile path.
    private func applyProjection(_ projection: [String: [PendingEchoItem]], sessionId: String) {
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
    }
}
