//
//  ChatPaginationWindow.swift
//  AgentVisorCore
//
//  Pure value-only pagination math for the chat timeline.
//
//  Why this exists: SwiftUI's LazyVStack virtualizes view *creation*
//  but its value-list pipeline (`_ViewList_Node.applyNodes` →
//  `_LazyLayout_Subviews.applyNodes`) walks the entire `[TimelineRow]`
//  array on every layout pass, copying each row's nested storage
//  (ChatHistoryItem → ChatHistoryItemType → ToolCallItem →
//  [ToolResultData]?) along the way. On a 153k-line JSONL session
//  that's thousands of rows and pins the main thread at 99% CPU
//  regardless of `.frame(maxHeight: .infinity)` or stable id keypaths.
//
//  Modern chat apps (Slack, Discord, ChatGPT, Claude Desktop, VS
//  Code Copilot Chat) handle this with a windowed slice + "Load
//  earlier messages" button. This type is the pure pagination math:
//  given a count of total items and a desired window size, produce
//  the slice range and a `hasMore` flag the UI uses to decide
//  whether to render the "Load earlier" button.
//

import Foundation

/// One round of pagination state. The view layer holds an instance,
/// hands it the current `totalItems` count, and renders only
/// `slice(...)` of the underlying array. Tapping "Load earlier"
/// returns a new state via `expanded()`.
public struct ChatPaginationWindow: Equatable, Sendable {
    /// Default rows shown on first load. Lowered from 500 to 100
    /// after migrating the chat bubble renderer to NSTextView-backed
    /// `SelectableMarkdownText`. Each NSTextView is wrapped in an
    /// NSViewRepresentable, which mounts an NSHostingView per row;
    /// SwiftUI's LazyVStack `LazyLayoutViewCache.updatePrefetchPhases`
    /// maintains an Update.Action array per realized row PLUS phantom
    /// entries for unrealized ones. At 500 rows, sidebar-divider
    /// drag triggers `_ArrayBuffer._consumeAndCreateNew` storms over
    /// the Update.Action array (sample: 366 ticks/sec, 100% CPU pin,
    /// 240 MB RSS climbing). At ~100 rows the array stays small
    /// enough that drag-time relayout is tractable.
    /// "Load earlier" still works for users who need more history.
    public static let defaultVisible: Int = 100

    /// Rows added per "Load earlier" tap. Matches `defaultVisible`
    /// so a single tap doubles the window — fast enough that users
    /// can ramp up to "show me everything" in a few taps without
    /// blowing past the resize-time safety threshold in one jump.
    public static let increment: Int = 100

    /// Hard cap on total visible rows in a single render pass. At
    /// 4000 rows the SwiftUI value-list pipeline starts re-introducing
    /// measurable layout overhead even with stable keypaths and
    /// `.frame(maxHeight: .infinity)`. Past this threshold we still
    /// allow expansion but warn callers via `isAtSafetyCap`.
    public static let safetyCap: Int = 4000

    /// Maximum rows the user has unlocked via "Load earlier". The
    /// actual rendered count is `min(visibleLimit, totalItems)`, so
    /// small sessions see the entire history and the limit only
    /// kicks in past `defaultVisible`.
    public let visibleLimit: Int

    public init(visibleLimit: Int = ChatPaginationWindow.defaultVisible) {
        self.visibleLimit = max(0, visibleLimit)
    }

    /// Returns the slice range (lower..<upper) into the source array.
    /// Always anchors to the END of the array — chat shows newest at
    /// bottom, so the visible window is the suffix.
    ///
    /// Pure function — same input always produces same output.
    /// Doesn't allocate, doesn't iterate the array.
    public func slice(totalItems: Int) -> Range<Int> {
        guard totalItems > 0 else { return 0..<0 }
        let visible = min(totalItems, visibleLimit)
        let start = totalItems - visible
        return start..<totalItems
    }

    /// True when the slice starts at index > 0, i.e. there is at
    /// least one earlier item not currently rendered. UI uses this
    /// to decide whether to show the "Load earlier messages" button.
    public func hasMore(totalItems: Int) -> Bool {
        slice(totalItems: totalItems).lowerBound > 0
    }

    /// How many rows are hidden above the current slice. UI uses
    /// this for the button label ("Load 1,234 earlier messages").
    public func hiddenCount(totalItems: Int) -> Int {
        max(0, slice(totalItems: totalItems).lowerBound)
    }

    /// Returns a new state with the visible window expanded by
    /// `increment`, capped at `totalItems` so we don't expand past
    /// what's actually loadable.
    public func expanded(totalItems: Int) -> ChatPaginationWindow {
        let next = min(visibleLimit + Self.increment, max(totalItems, visibleLimit))
        return ChatPaginationWindow(visibleLimit: next)
    }

    /// True once the visible window covers everything; UI hides
    /// the "Load earlier" button at this point.
    public func isFullyExpanded(totalItems: Int) -> Bool {
        visibleLimit >= totalItems
    }

    /// True once the visible window has crossed the safety cap. UI
    /// can use this to surface a quieter warning (e.g. dim the
    /// button) — we don't *block* expansion past it because the
    /// user has explicitly asked for it, but we want the affordance
    /// to acknowledge the trade-off.
    public func isAtSafetyCap(totalItems: Int) -> Bool {
        let visible = min(totalItems, visibleLimit)
        return visible >= Self.safetyCap
    }
}
