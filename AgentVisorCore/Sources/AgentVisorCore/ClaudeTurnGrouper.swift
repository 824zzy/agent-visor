//
//  ClaudeTurnGrouper.swift
//  AgentVisorCore
//
//  Codex-style turn collapsing for Claude Code chat. Claude Code's TUI
//  writes a `turn_duration` system row that CLOSES each turn (it trails
//  the turn's work + final answer). This grouper segments an ordered,
//  oldest-first item list on those trailing markers and, per closed
//  turn, folds the work (tool calls / thinking / local output /
//  interrupted) under the marker as a collapsible "Worked for X" header
//  while keeping ONLY the final assistant answer visible:
//
//      [prompt] → [✻ Worked for X  (work hidden)] → [final answer]
//
//  Intermediate narration (assistant text emitted BEFORE the turn's last
//  work item) is dropped — its ids are simply absent from the output.
//  Pure-text turns (no work) emit no header. Any run AFTER the last
//  marker (a live, still-running turn) or BEFORE the first marker (a
//  pagination cut) is emitted flat/standalone, so the live turn stays
//  expanded until its closing marker lands.
//
//  Pure / value-in-value-out so it's unit-testable without view state,
//  the same way TurnCollapsePlanner and the Codex parsers are.
//

import Foundation

public enum ClaudeTurnGrouper {
    /// Coarse classification of a timeline item, derived by the App from
    /// `ChatHistoryItemType`. Only what the segmentation needs.
    public enum ItemCategory: Equatable, Sendable {
        /// User prompt / image — opens a turn, never folded.
        case prompt
        /// Assistant prose. Narration vs. final answer is decided by
        /// position relative to the turn's last work item.
        case assistantText
        /// Tool call / thinking / local command output / interrupted —
        /// the foldable "work" of a turn. `hasError` drives the header
        /// warning glyph.
        case work(hasError: Bool)
        /// `turn_duration` — closes a turn; becomes the header parent.
        case turnMarker
        /// recap / compact-boundary — session-level, always standalone.
        case sessionLevel
        /// An item that requires the user to act — an `AskUserQuestion`
        /// prompt or a tool awaiting approval. NEVER folded and never
        /// counted as a work step: hiding the thing that's blocking
        /// progress behind a collapsed "Worked" header is the opposite of
        /// useful. Always a standalone, fully-visible row. Treated like
        /// `sessionLevel` for segmentation — it does not move the
        /// narration/final-answer boundary.
        case interactive
    }

    public struct ItemDescriptor: Equatable, Sendable {
        public let id: String
        public let category: ItemCategory

        public init(id: String, category: ItemCategory) {
            self.id = id
            self.category = category
        }
    }

    /// Suffix appended to the first work item's id to form the synthetic
    /// header id for a LIVE (still-streaming, no closing marker) turn.
    /// The App maps a `parentId` carrying this — flagged by `isLive` — to a
    /// synthesized "Working…" header rather than a real `turn_duration`
    /// item.
    public static let liveHeaderSuffix = "-livehdr"

    /// One visible row. When `childIds` is non-empty this is a collapsible
    /// turn: for a COMPLETED turn `parentId` is the `turnMarker`'s id; for a
    /// LIVE turn (`isLive == true`) `parentId` is a synthetic id and the App
    /// synthesizes the header. When `childIds` is empty it's a standalone
    /// row and `parentId` is that item's own id.
    public struct GroupedRow: Equatable, Sendable {
        public let parentId: String
        public let childIds: [String]
        public let hasError: Bool
        public let stepCount: Int
        /// True for the in-progress turn's header (no closing marker yet) —
        /// drives "Working…" vs "Worked for X".
        public let isLive: Bool

        public init(parentId: String, childIds: [String], hasError: Bool, stepCount: Int, isLive: Bool = false) {
            self.parentId = parentId
            self.childIds = childIds
            self.hasError = hasError
            self.stepCount = stepCount
            self.isLive = isLive
        }

        /// Convenience for the common standalone case.
        static func standalone(_ id: String) -> GroupedRow {
            GroupedRow(parentId: id, childIds: [], hasError: false, stepCount: 0, isLive: false)
        }
    }

    /// Segment `items` into ordered visible rows. Narration ids are
    /// omitted entirely; the App drops any source item not referenced as
    /// a `parentId` or a child.
    ///
    /// Both COMPLETED turns (closed by a `turnMarker`) and the LIVE
    /// trailing turn (still streaming, no marker yet) get the same
    /// treatment: work folds under a header, intermediate narration is
    /// dropped, only the trailing text survives. The live turn's header is
    /// synthetic (`isLive: true`) and shows "Working…" instead of a
    /// duration. A leading orphan (pagination cut before the first marker)
    /// is treated as a closed turn too — only the marker decides, so the
    /// genuinely live case is exactly "the run after the last marker."
    public static func group(_ items: [ItemDescriptor]) -> [GroupedRow] {
        var out: [GroupedRow] = []
        var turn: [ItemDescriptor] = []

        for item in items {
            if case .turnMarker = item.category {
                out.append(contentsOf: foldTurn(body: turn, headerId: item.id, isLive: false))
                turn.removeAll(keepingCapacity: true)
            } else {
                turn.append(item)
            }
        }

        // The run after the last marker is the live, in-progress turn.
        // Fold it the same way, with a synthetic "Working…" header.
        if !turn.isEmpty {
            let headerId = (turn.first { if case .work = $0.category { return true }; return false }?.id ?? turn[0].id) + liveHeaderSuffix
            out.append(contentsOf: foldTurn(body: turn, headerId: headerId, isLive: true))
        }
        return out
    }

    /// Build the rows for one turn. `body` is the items belonging to the
    /// turn (excluding any marker); `headerId` is the parent id to use for
    /// the collapsible header (a real `turn_duration` id for a completed
    /// turn, or a synthetic id for the live turn).
    private static func foldTurn(body: [ItemDescriptor], headerId: String, isLive: Bool) -> [GroupedRow] {
        // Index of this turn's last work item — the boundary between
        // narration (before) and the final answer (after).
        var lastWorkIndex: Int? = nil
        for (i, item) in body.enumerated() {
            if case .work = item.category { lastWorkIndex = i }
        }

        guard let lastWork = lastWorkIndex else {
            // No work: pure-text (or prompt-only) turn. Emit body flat,
            // no header — avoids a "Worked for 0s" / empty "Working…" row.
            return body.map { .standalone($0.id) }
        }

        var rows: [GroupedRow] = []
        var childIds: [String] = []
        var hasError = false
        var headerEmitted = false

        // session-level items (recap / compact-boundary) and interactive
        // items (AskUserQuestion / pending approval) are never folded;
        // they break out as standalone, fully-visible rows wherever they
        // sit. (Both already excluded from `lastWork` above, so they don't
        // move the narration/final-answer boundary.)
        for (i, item) in body.enumerated() {
            switch item.category {
            case .prompt, .sessionLevel, .interactive:
                rows.append(.standalone(item.id))
            case .work(let err):
                if !headerEmitted {
                    // Reserve the header slot at the first work item so the
                    // collapsed turn sits where the work began (after the
                    // prompt, before the final answer).
                    rows.append(GroupedRow(parentId: headerId, childIds: [], hasError: false, stepCount: 0, isLive: isLive))
                    headerEmitted = true
                }
                childIds.append(item.id)
                hasError = hasError || err
            case .assistantText:
                if i > lastWork {
                    // Final answer (or, for a live turn, the latest
                    // streaming text) — keep, prominent, after the header.
                    rows.append(.standalone(item.id))
                }
                // else: narration before the last work item → dropped.
            case .turnMarker:
                break // unreachable: markers never enter `body`
            }
        }

        // Replace the reserved header placeholder with the finalized one
        // now that childIds/hasError are known.
        if headerEmitted, let slot = rows.firstIndex(where: { $0.parentId == headerId }) {
            rows[slot] = GroupedRow(
                parentId: headerId,
                childIds: childIds,
                hasError: hasError,
                stepCount: childIds.count,
                isLive: isLive
            )
        }
        return rows
    }
}
