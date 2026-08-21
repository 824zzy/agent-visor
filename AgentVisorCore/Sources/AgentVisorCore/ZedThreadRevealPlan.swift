//
//  ZedThreadRevealPlan.swift
//  AgentVisorCore
//
//  Plans the keystroke batch that reveals one Zed thread.
//
//  Why keystrokes at all: Zed has no thread deeplink. Verified against
//  Zed 1.14 / `main`:
//    * `zed://agent` maps to `OpenRequestKind::AgentPanel`, which calls
//      `new_agent_thread_with_external_source_prompt` — it always creates
//      a NEW thread in an arbitrary active workspace, so it is the wrong
//      primitive for "return to this thread";
//    * the `zed` CLI exposes no agent/thread flag;
//    * Zed's GPUI accessibility tree publishes only window chrome (probed:
//      three buttons, no rows), so an AX press on a sidebar row is
//      impossible.
//
//  What DOES exist is Zed's own keyboard path, which works for threads
//  whose workspace is closed too (`menu::Confirm` on a sidebar thread
//  routes through `open_workspace_and_activate_thread`):
//
//      cmd-shift-p opens the command palette, establishing a known
//                  non-sidebar focus state
//      cmd-alt-;   multi_workspace::FocusWorkspaceSidebar; dispatched
//                  immediately so the palette never needs a typed query
//      cmd-f       agents_sidebar::FocusSidebarFilter
//      cmd-a, del  replace any filter left by the user
//      <title>     filters the thread list
//      down ×2     menu::SelectNext — filtering CLEARS the selection
//                  (`selection.take()`) and keeps the matching project
//                  header before its thread, so the first Down selects the
//                  header and the second selects the thread
//      enter       menu::Confirm — activates the selected thread
//
//  After verification, cleanup reanchors focus in the ThreadsSidebar,
//  clears the filter, and uses Zed's direct `agent::ToggleFocus` shortcut.
//  Activating a different thread can move focus back to the workspace
//  editor, so cleanup must not assume Confirm left the sidebar focused.
//  The plan is pure so the sequence, its delays, and its refusal cases
//  are testable without driving CGEvents. Execution, focus checks, and
//  verification live in the app layer.
//

import Foundation

/// Keys the Zed reveal needs, named by intent rather than keycode so the
/// pure plan stays independent of Carbon virtual-key constants.
public enum ZedRevealKey: Equatable, Sendable {
    /// `command_palette::Toggle` (default cmd-shift-p). Besides avoiding
    /// punctuation-key layout differences, the palette takes focus before
    /// the sidebar action runs, making FocusWorkspaceSidebar deterministic.
    case openCommandPalette
    /// `multi_workspace::FocusWorkspaceSidebar` (default cmd-alt-;).
    /// The command palette establishes the non-sidebar precondition that
    /// makes this otherwise-toggle-like action deterministic.
    case focusWorkspaceSidebar
    /// `agents_sidebar::FocusSidebarFilter` (default cmd-f in the
    /// ThreadsSidebar context).
    case focusSidebarFilter
    /// Select all text in the focused filter editor (default cmd-a).
    case selectAll
    /// Delete the selected filter text.
    case deleteBackward
    /// `menu::Cancel` (default escape). In Zed's ThreadsSidebar this clears
    /// a non-empty filter whether the filter editor or a result owns focus.
    case cancel
    /// `agent::ToggleFocus` (default cmd-?). Only used after a confirmed
    /// reveal, whose focus is known to be in ThreadsSidebar, so it focuses
    /// the Agent Panel instead of closing it.
    case focusAgentFromSidebar
    /// `menu::SelectNext` (default down).
    case selectNext
    /// `menu::Confirm` (default enter).
    case confirm
}

public enum ZedRevealStep: Equatable, Sendable {
    case key(ZedRevealKey)
    case text(String)
    /// Seconds to wait before the next step so GPUI can re-render the
    /// filtered list before the selection and confirm land.
    case delay(Double)
}

public enum ZedThreadRevealPlanner {
    /// Long titles are truncated: Zed's filter is a fuzzy subsequence
    /// match, so a prefix selects the same thread while keeping the typed
    /// burst short.
    public static let maximumQueryLength = 48

    /// Filter text for a thread title, or nil when the title cannot
    /// identify a row (no title yet → nothing to type; typing an empty
    /// query would leave the whole list unfiltered and Confirm would open
    /// whatever happened to be first).
    public static func query(forTitle title: String?) -> String? {
        guard let title else { return nil }
        let collapsed = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumQueryLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Steps that reveal `title`, or `[]` when no reveal is possible.
    /// `settleDelay` is the pause GPUI needs after a state transition.
    public static func plan(
        title: String?,
        settleDelay: Double = 0.12
    ) -> [ZedRevealStep] {
        guard let query = query(forTitle: title) else { return [] }
        return focusSidebarFilterSteps(settleDelay: settleDelay) + [
            .key(.selectAll),
            .key(.deleteBackward),
            .text(query),
            .delay(settleDelay),
            .key(.selectNext),
            .key(.selectNext),
            .delay(settleDelay),
            .key(.confirm)
        ]
    }

    /// Clears the search after a verified reveal, then focuses the active
    /// thread composer. Activating a different thread can return focus to the
    /// workspace editor, so the transient palette anchor restores a known
    /// ThreadsSidebar state before Cancel and the direct ToggleFocus shortcut.
    /// No action name is typed, and the synchronous Cancel needs no extra wait,
    /// keeping deliberate cleanup latency at two settle delays.
    public static func cleanupPlan(settleDelay: Double = 0.12) -> [ZedRevealStep] {
        [
            .key(.openCommandPalette),
            .key(.focusWorkspaceSidebar),
            .delay(settleDelay),
            .key(.cancel),
            .key(.focusAgentFromSidebar),
            .delay(settleDelay)
        ]
    }

    private static func focusSidebarFilterSteps(
        settleDelay: Double
    ) -> [ZedRevealStep] {
        [
            .key(.openCommandPalette),
            .key(.focusWorkspaceSidebar),
            .delay(settleDelay),
            .key(.focusSidebarFilter),
            .delay(settleDelay)
        ]
    }
}

/// What actually happened after a reveal batch, decided from Zed's
/// persisted active-workspace Agent Panel selection.
public enum ZedThreadRevealOutcome: Equatable, Sendable {
    /// Zed's active workspace persisted the target thread.
    case revealed
    /// The active workspace persisted another thread (the fuzzy filter
    /// matched a neighbour first). Reported honestly rather than claimed
    /// as success.
    case openedDifferentThread(threadID: String)
    /// No active-workspace receipt: Zed ignored the batch, the requested
    /// workspace did not become active, or the panel was not registered.
    /// Caller falls back to the toast.
    case unverified
}

/// The thread Zed persisted as active for one workspace's Agent Panel.
/// Zed serializes this state after `load_agent_thread`; unlike
/// `sidebar_threads.interacted_at`, it changes for keyboard-driven loads.
public struct ZedThreadSelection: Equatable, Sendable {
    public let threadID: String?
    public let sessionID: String?

    public init(threadID: String?, sessionID: String?) {
        self.threadID = threadID
        self.sessionID = sessionID
    }
}

public enum ZedThreadRevealVerifier {
    /// Verifies against Zed's serialized Agent Panel selection. Thread ids
    /// are accepted in either SQLite hex form or UUID form.
    public static func outcome(
        targetThreadID: String,
        targetSessionID: String?,
        selection: ZedThreadSelection?
    ) -> ZedThreadRevealOutcome {
        guard let selection else { return .unverified }
        if matches(
            selection: selection,
            targetThreadID: targetThreadID,
            targetSessionID: targetSessionID
        ) {
            return .revealed
        }
        if let threadID = selection.threadID, !threadID.isEmpty {
            return .openedDifferentThread(threadID: threadID)
        }
        if let sessionID = selection.sessionID, !sessionID.isEmpty {
            return .openedDifferentThread(threadID: sessionID)
        }
        return .unverified
    }

    private static func matches(
        selection: ZedThreadSelection,
        targetThreadID: String,
        targetSessionID: String?
    ) -> Bool {
        if let selectedThreadID = selection.threadID,
           canonicalThreadID(selectedThreadID) == canonicalThreadID(targetThreadID) {
            return true
        }
        if let targetSessionID,
           let selectedSessionID = selection.sessionID,
           selectedSessionID.caseInsensitiveCompare(targetSessionID) == .orderedSame {
            return true
        }
        return false
    }

    private static func canonicalThreadID(_ raw: String) -> String {
        raw
            .filter { $0 != "-" }
            .lowercased()
    }
}
