//
//  CursorSessionTitleStore.swift
//  AgentVisor
//
//  Holds per-session titles as set by Cursor's claude-code extension
//  webview. Populated by CursorSessionTitleWatcher (which tails the
//  extension's log files). Consumed by InstanceRow to render pills with
//  the same name Cursor uses in its tab strip — so a user with multiple
//  CC sessions can tell them apart at a glance, even though Cursor's
//  extension doesn't expose a /rename slash command.
//

import Combine
import Foundation

@MainActor
final class CursorSessionTitleStore: ObservableObject {
    static let shared = CursorSessionTitleStore()

    @Published private(set) var titles: [String: String] = [:]

    private init() {}

    func setTitle(_ title: String, forSessionId sessionId: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if titles[sessionId] != trimmed {
            titles[sessionId] = trimmed
            Self.updateShadow(sessionId: sessionId, title: trimmed)
        }
    }

    func title(forSessionId sessionId: String) -> String? {
        titles[sessionId]
    }

    // MARK: - nonisolated shadow

    /// Thread-safe snapshot of `titles` for callers that can't hop to
    /// MainActor (e.g., `CursorAXSender.send` runs on a background
    /// queue under TerminalAdapterRegistry's dispatch path). Reads
    /// may be one mutation behind the @Published copy, which is fine
    /// — we only use the title to fuzzy-match a Cursor tab name.
    nonisolated private static let shadowLock = NSLock()
    nonisolated(unsafe) private static var shadow: [String: String] = [:]

    nonisolated static func snapshotTitle(forSessionId sessionId: String) -> String? {
        shadowLock.lock()
        defer { shadowLock.unlock() }
        return shadow[sessionId]
    }

    nonisolated private static func updateShadow(sessionId: String, title: String) {
        shadowLock.lock()
        defer { shadowLock.unlock() }
        shadow[sessionId] = title
    }
}
