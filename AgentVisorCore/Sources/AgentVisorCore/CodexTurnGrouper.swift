//
//  CodexTurnGrouper.swift
//  AgentVisorCore
//
//  Codex-style turn collapsing for Codex chat. Unlike Claude Code (whose
//  `turn_duration` row TRAILS each turn), Codex inserts its duration block
//  right after the user prompt — a LEADING marker — and only on
//  `task_complete` (an aborted turn gets none). So this grouper can't key
//  on the marker the way `ClaudeTurnGrouper` does; instead it segments on
//  USER-PROMPT boundaries (every Codex turn opens with a prompt) and folds
//  each turn's work under a leading "Worked …" header while keeping only
//  the trailing final answer visible:
//
//      [prompt] → [✻ Worked …  (work hidden)] → [final answer]
//
//  Differences from `ClaudeTurnGrouper`, all intentional:
//   - prompt-opens-turn (not trailing-marker-closes-turn);
//   - interim narration is FOLDED as collapsible children, NOT dropped
//     (Codex commentary carries progress signal — matches Codex Desktop's
//     disclosure). Codex maps commentary to `.thinking` → `.work`, so it
//     folds for free; a non-trailing `assistantText` is folded too;
//   - the header is LEADING — placed at the first foldable item, fed by the
//     leading `turn_duration` id when present.
//
//  The live (in-progress) turn — the last turn with no closing duration
//  while the session is still processing — folds into a synthetic
//  "Working…" header (`liveHeaderSuffix`). A completed-but-aborted turn
//  (work, no duration, not processing) gets a static synthetic header
//  (`abortedHeaderSuffix`).
//
//  Pure / value-in-value-out so it's unit-testable without view state.
//

import Foundation

public enum CodexTurnGrouper {
    /// Coarse classification of a timeline item, derived by the App from
    /// `ChatHistoryItemType`. Only what the segmentation needs.
    public enum ItemCategory: Equatable, Sendable {
        /// User prompt / image — OPENS a turn, never folded.
        case prompt
        /// Final assistant answer (`phase == final_answer` or none). Kept
        /// prominent when it trails the turn's work; folded as a child when
        /// it precedes a later work item.
        case assistantText
        /// Commentary (→ thinking) / toolCall / terminal / local output /
        /// interrupted — the foldable "work" of a turn. `hasError` drives
        /// the header warning glyph.
        case work(hasError: Bool)
        /// `turn_duration` — a LEADING marker; supplies the header id +
        /// duration. Never rendered as a child.
        case turnMarker
        /// recap / compact-boundary — session-level, always standalone.
        case sessionLevel
        /// An item that requires the user to act — an `AskUserQuestion`
        /// prompt or a tool awaiting approval. Never folded, never a step;
        /// always a standalone, fully-visible row.
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

    /// Suffix forming the synthetic header id for a LIVE (in-progress,
    /// still-streaming) turn. The App maps a `parentId` carrying this to a
    /// synthesized "Working…" header.
    public static let liveHeaderSuffix = "-livehdr"

    /// Suffix forming the synthetic header id for a COMPLETED turn that
    /// carries no duration block (an aborted turn, or one Codex finished
    /// without a `duration_ms`). Renders a static "Worked" header with no
    /// elapsed time.
    public static let abortedHeaderSuffix = "-codexhdr"

    /// One visible row. When `childIds` is non-empty this is a collapsible
    /// turn: `parentId` is the `turnMarker`'s id for a completed turn that
    /// carried a duration, or a synthetic id (`isLive`/aborted) otherwise.
    /// When `childIds` is empty it's a standalone row and `parentId` is that
    /// item's own id.
    public struct GroupedRow: Equatable, Sendable {
        public let parentId: String
        public let childIds: [String]
        public let hasError: Bool
        public let stepCount: Int
        /// True for the in-progress turn's header — drives "Working…" vs
        /// "Worked".
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

    /// Segment `items` (oldest-first) into ordered visible rows.
    ///
    /// `sessionIsProcessing` decides whether the FINAL turn that lacks a
    /// closing duration renders live ("Working…") or static ("Worked").
    public static func group(_ items: [ItemDescriptor], sessionIsProcessing: Bool) -> [GroupedRow] {
        guard !items.isEmpty else { return [] }

        // Split into turns on user-prompt boundaries. Any items before the
        // first prompt (a pagination cut above the prompt) form a leading
        // orphan turn — handled the same as any other turn.
        var turns: [[ItemDescriptor]] = []
        var current: [ItemDescriptor] = []
        for item in items {
            if case .prompt = item.category {
                if !current.isEmpty { turns.append(current) }
                current = [item]
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { turns.append(current) }

        var out: [GroupedRow] = []
        for (idx, turn) in turns.enumerated() {
            let isLast = idx == turns.count - 1
            let markerId = turn.first(where: { if case .turnMarker = $0.category { return true }; return false })?.id
            let firstWorkId = turn.first(where: { if case .work = $0.category { return true }; return false })?.id
            // Live only when this is the trailing turn, it has work to fold,
            // it has no closing duration yet, and the session is processing.
            // A duration block means the turn ended → never live, even mid-
            // session.
            let isLive = isLast && markerId == nil && sessionIsProcessing && firstWorkId != nil

            let headerId: String
            if let markerId {
                headerId = markerId
            } else if let firstWorkId {
                headerId = firstWorkId + (isLive ? liveHeaderSuffix : abortedHeaderSuffix)
            } else {
                headerId = "" // no work in the turn → no header; value unused
            }
            out.append(contentsOf: foldTurn(body: turn, headerId: headerId, isLive: isLive))
        }
        return out
    }

    /// Build the rows for one turn. `body` is every item of the turn
    /// (including the leading `turnMarker`, which is dropped here);
    /// `headerId` is the collapsible header's parent id.
    private static func foldTurn(body: [ItemDescriptor], headerId: String, isLive: Bool) -> [GroupedRow] {
        // Boundary between foldable work (before) and the final answer
        // (after): the index of the turn's last work item.
        var lastWorkIndex: Int? = nil
        for (i, item) in body.enumerated() {
            if case .work = item.category { lastWorkIndex = i }
        }

        guard let lastWork = lastWorkIndex else {
            // No work: pure prompt/text turn. Emit non-marker items flat,
            // no header — avoids an empty "Worked"/"Working…" chip.
            return body.compactMap { item in
                if case .turnMarker = item.category { return nil }
                return GroupedRow.standalone(item.id)
            }
        }

        var rows: [GroupedRow] = []
        var childIds: [String] = []
        var hasError = false
        var headerEmitted = false

        func emitHeaderPlaceholderIfNeeded() {
            guard !headerEmitted else { return }
            // Reserve the header slot at the first foldable item so the
            // collapsed turn sits right after the prompt, before the answer.
            rows.append(GroupedRow(parentId: headerId, childIds: [], hasError: false, stepCount: 0, isLive: isLive))
            headerEmitted = true
        }

        for (i, item) in body.enumerated() {
            switch item.category {
            case .prompt, .sessionLevel, .interactive:
                // Never folded; always a standalone, fully-visible row.
                rows.append(.standalone(item.id))
            case .turnMarker:
                break // dropped — supplies the header id, never a rendered child
            case .work(let err):
                emitHeaderPlaceholderIfNeeded()
                childIds.append(item.id)
                hasError = hasError || err
            case .assistantText:
                if i > lastWork {
                    // Trailing run → the final answer. Keep prominent.
                    rows.append(.standalone(item.id))
                } else {
                    // Interim assistant text before the turn's last work →
                    // fold as a child so only the final answer stays prominent.
                    emitHeaderPlaceholderIfNeeded()
                    childIds.append(item.id)
                }
            }
        }

        // Finalize the reserved header now that childIds/hasError are known.
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
