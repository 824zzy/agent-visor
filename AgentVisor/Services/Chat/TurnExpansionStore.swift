//
//  TurnExpansionStore.swift
//  AgentVisor
//
//  Per-session set of EXPANDED turn ids for the window chat's
//  collapsible "Worked for X" turns. Codex-desktop behavior is
//  collapsed-by-default, so a turn id is absent until the user taps
//  its chevron — `toggle(...)` flips membership.
//
//  Lives outside the per-session WindowChatViewModel (which is
//  recreated on every session switch via `.id(sessionId)`) so an
//  expanded turn stays expanded across view churn. The table cell
//  reads/toggles through the shared instance; the view-model observes
//  the @Published set and re-runs its flatten so the planner
//  (`TurnCollapsePlanner`) shows/hides children.
//

import Combine
import Foundation

@MainActor
final class TurnExpansionStore: ObservableObject {
    static let shared = TurnExpansionStore()

    /// Per-session set of expanded turn (parent) ids. Empty set ⇒ all
    /// turns collapsed (the default). Public for view-model observation.
    @Published private(set) var expandedBySession: [String: Set<String>] = [:]

    private init() {}

    /// Expanded turn ids for `sessionId` (empty when none).
    func expanded(for sessionId: String) -> Set<String> {
        expandedBySession[sessionId] ?? []
    }

    /// Whether `turnId` is currently expanded in `sessionId`.
    func isExpanded(sessionId: String, turnId: String) -> Bool {
        expandedBySession[sessionId]?.contains(turnId) ?? false
    }

    /// Flip the expanded state of `turnId` within `sessionId`.
    func toggle(sessionId: String, turnId: String) {
        var set = expandedBySession[sessionId] ?? []
        if set.contains(turnId) {
            set.remove(turnId)
        } else {
            set.insert(turnId)
        }
        expandedBySession[sessionId] = set
    }
}
