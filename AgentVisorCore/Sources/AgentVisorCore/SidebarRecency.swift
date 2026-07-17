//
//  SidebarRecency.swift
//  AgentVisorCore
//
//  Resolves the date a session sorts by in the sidebar recency list.
//
//  History: the sort used `lastUserMessageDate ?? lastActivity`. On
//  large / compacted transcripts the head+tail summary parser only
//  matches *string-content* user turns, so a session whose recent
//  human turns are array-shaped (image paste / tool_result wrappers)
//  resolves `lastUserMessageDate` to an ancient head-of-file turn and
//  sinks to the bottom of the list even though it's the most recently
//  active. `lastActivityDate` (timestamp of the last message of ANY
//  role, both content shapes — see ConversationInfo.lastActivityDate)
//  is a strong transcript signal, while `lastActivity` carries file/watch
//  recency when the parser lags behind the rollout file.
//
//  Pure / value-in-value-out so it's unit-testable without a clock or
//  a SessionState.
//

import Foundation

public enum SidebarRecency {
    /// The date a session sorts by, newest-first. Uses the newest
    /// available activity signal: parsed transcript activity, legacy
    /// user-message activity, or file/watch activity.
    public static func sortDate(
        lastActivityDate: Date?,
        lastUserMessageDate: Date?,
        lastActivity: Date
    ) -> Date {
        [lastActivityDate, lastUserMessageDate, lastActivity].compactMap { $0 }.max() ?? lastActivity
    }

    /// Newest-first row comparison for the flat sidebar. Phase is a
    /// tie-breaker only; attention-required sessions are partitioned by the
    /// caller before this comparator runs.
    public static func precedes(
        lhsDate: Date,
        rhsDate: Date,
        lhsPhasePriority: Int,
        rhsPhasePriority: Int,
        lhsID: String,
        rhsID: String
    ) -> Bool {
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhsPhasePriority != rhsPhasePriority { return lhsPhasePriority < rhsPhasePriority }
        return lhsID < rhsID
    }
}
