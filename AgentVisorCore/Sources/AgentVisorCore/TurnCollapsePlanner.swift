//
//  TurnCollapsePlanner.swift
//  AgentVisorCore
//
//  Pure flatten-with-collapse for the window chat's "Worked for X"
//  turns. The window renders a flat NSTableView, so the nested
//  turn-duration grouping (parent + its intermediate-step children)
//  must be linearized into ordered rows. This planner decides which
//  rows appear and at what indent depth, honoring a set of expanded
//  turn ids.
//
//  Codex-desktop behavior is collapsed-by-default: a turn's steps are
//  hidden until the user expands that turn (empty `expanded` set ⇒
//  every turn collapsed). Standalone rows (no children) always show.
//
//  Pure / value-in-value-out so it's unit-testable without any view
//  state, the same way ChatRowDiff and the Codex parsers are.
//

import Foundation

public enum TurnCollapsePlanner {
    /// One timeline group: a parent row and its (possibly empty) ordered
    /// child rows. A group with no children is a standalone row; a group
    /// with children is a collapsible "Worked for X" turn.
    public struct RowGroup: Equatable, Sendable {
        public let parentId: String
        public let childIds: [String]

        public init(parentId: String, childIds: [String]) {
            self.parentId = parentId
            self.childIds = childIds
        }
    }

    /// One planned row: the row id and its indent depth (0 = top-level
    /// parent/standalone, 1 = child of an expanded turn).
    public struct PlannedRow: Equatable, Sendable {
        public let id: String
        public let depth: Int

        public init(id: String, depth: Int) {
            self.id = id
            self.depth = depth
        }
    }

    /// Linearize `groups` into the visible ordered row list. A group's
    /// children are emitted (at depth 1) only when its `parentId` is in
    /// `expanded`; otherwise just the parent shows. Order is preserved.
    public static func plan(groups: [RowGroup], expanded: Set<String>) -> [PlannedRow] {
        var out: [PlannedRow] = []
        out.reserveCapacity(groups.count)
        for group in groups {
            out.append(PlannedRow(id: group.parentId, depth: 0))
            guard !group.childIds.isEmpty, expanded.contains(group.parentId) else {
                continue
            }
            for child in group.childIds {
                out.append(PlannedRow(id: child, depth: 1))
            }
        }
        return out
    }
}
