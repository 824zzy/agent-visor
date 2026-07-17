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
//      • evict(by id): remove a single echo. TTL backstop in the store
//        targets a specific echo by id; tests exercise both single-
//        item and last-item-removes-entry paths.
//      • evictAll(sessionId:): drop all pending echoes for a session.
//        Triggered by ESC-cancel: the canceled query may already be
//        in JSONL (so the real bubble stays), and the duplicate echo
//        bubble must go.
//      • reconcile: text-match echoes against the newest real user
//        turns from JSONL; matching echoes evict.
//

import Foundation

/// Lightweight, type-erased echo entry. PendingEchoStore wraps each
/// real `ChatHistoryItem` echo into one of these so Core stays free
/// of main-app types.
public struct PendingEchoItem: Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum PendingEchoLogic {
    /// Append an echo to `state[sessionId]`. Empty / whitespace-only
    /// text is a no-op (the user hit Enter on a blank composer; we
    /// don't want a phantom empty bubble).
    public static func push(
        into state: [String: [PendingEchoItem]],
        sessionId: String,
        id: String,
        text: String
    ) -> [String: [PendingEchoItem]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state }
        var next = state
        next[sessionId, default: []].append(PendingEchoItem(id: id, text: text))
        return next
    }

    /// Drop all pending echoes for `sessionId`. Used by ESC-cancel:
    /// the canceled-but-already-sent query is canonical in JSONL, so
    /// the optimistic echo bubble (a sibling row with synthetic id)
    /// has to evict to avoid showing the user's bubble twice.
    public static func evictAll(
        from state: [String: [PendingEchoItem]],
        sessionId: String
    ) -> [String: [PendingEchoItem]] {
        guard state[sessionId] != nil else { return state }
        var next = state
        next.removeValue(forKey: sessionId)
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
        let normalizedReals = Set(realUserTexts.map(normalizeForReconcile).filter { !$0.isEmpty })
        let kept = pending.filter { echo in
            let key = normalizeForReconcile(echo.text)
            return key.isEmpty || !normalizedReals.contains(key)
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
