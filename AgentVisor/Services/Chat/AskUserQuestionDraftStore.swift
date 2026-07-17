//
//  AskUserQuestionDraftStore.swift
//  AgentVisor
//
//  In-memory store for in-progress AskUserQuestion form state, keyed by
//  sessionId. Sibling of `DraftStore` (which holds the chat-input draft).
//  The two are kept separate because they answer different prompts:
//    - DraftStore: free-form prompt the user is composing.
//    - AskUserQuestionDraftStore: structured answers to a tool's
//      multiple-choice / "Other" form, fingerprint-keyed so a stale
//      draft against a changed prompt is silently discarded.
//
//  Lifetime is one app launch (RAM only). Cleared on session end via
//  SessionStore.processSessionEnd, mirroring DraftStore.
//

import AgentVisorCore
import Foundation

/// One stored AskUserQuestion draft: the user's in-progress answers
/// (`snapshot`) plus the content fingerprint of the prompt those
/// answers were typed against. The fingerprint guards reads — a draft
/// stored against prompt A is discarded if read against prompt B,
/// even if the sessionId matches. See
/// `AskUserQuestionDraftFingerprint` for what the hash covers.
struct AskUserQuestionDraftEntry: Equatable {
    let fingerprint: String
    var snapshot: QuestionFlowSnapshot
}

@MainActor
final class AskUserQuestionDraftStore {
    static let shared = AskUserQuestionDraftStore()

    private var entries: [String: AskUserQuestionDraftEntry] = [:]

    private init() {}

    /// Read a draft if one exists AND its fingerprint matches the
    /// currently-displayed prompt. Returns nil on miss OR mismatch.
    /// The mismatch path silently discards the stored entry — once
    /// the prompt has changed shape, the draft can never be valid
    /// again, so there's no reason to keep it taking up space.
    func get(sessionId: String, fingerprint: String) -> QuestionFlowSnapshot? {
        guard let entry = entries[sessionId] else { return nil }
        if entry.fingerprint != fingerprint {
            entries.removeValue(forKey: sessionId)
            return nil
        }
        return entry.snapshot
    }

    /// Write-through from the live `QuestionFlowState`. Called on every
    /// `@Published` mutation so the saved draft never trails the UI by
    /// more than a single main-thread hop. Empty snapshots (no answers,
    /// step 0) are kept rather than pruned — a user landing on the
    /// form, then immediately dipping out, expects to come back to
    /// step 0; we don't need a special "empty means delete" rule.
    func save(sessionId: String, fingerprint: String, snapshot: QuestionFlowSnapshot) {
        entries[sessionId] = AskUserQuestionDraftEntry(
            fingerprint: fingerprint,
            snapshot: snapshot
        )
    }

    /// Drop the draft. Called eagerly from submit() / cancel() in
    /// AskUserQuestionPendingContent (BEFORE the socket round-trip)
    /// so a partially-completed submit can't leave a stale draft, and
    /// from SessionStore.processSessionEnd so dead sessions don't
    /// keep their drafts around.
    func clear(sessionId: String) {
        entries.removeValue(forKey: sessionId)
    }
}
