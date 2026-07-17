//
//  DraftStore.swift
//  AgentVisor
//
//  In-memory store for unsent chat drafts, keyed by sessionId. Lets the
//  notch chat view survive close/reopen and tab switches without losing
//  whatever the user was typing (or any attached images).
//
//  Scope is a single app launch: drafts live in RAM only. That's aligned
//  with temp-image-file lifetime, which gets swept on launch anyway.
//

import Foundation

struct ChatDraft {
    var text: String
    var attachments: [ImageAttachment]

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }
}

@MainActor
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [String: ChatDraft] = [:]

    private init() {}

    func load(sessionId: String) -> ChatDraft? {
        drafts[sessionId]
    }

    /// Empty drafts are deleted rather than stored so the dictionary doesn't
    /// grow forever with no-op entries.
    func save(sessionId: String, text: String, attachments: [ImageAttachment]) {
        let draft = ChatDraft(text: text, attachments: attachments)
        if draft.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = draft
        }
    }

    func clear(sessionId: String) {
        drafts.removeValue(forKey: sessionId)
    }
}
