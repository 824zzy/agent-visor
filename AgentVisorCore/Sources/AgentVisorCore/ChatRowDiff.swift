//
//  ChatRowDiff.swift
//  AgentVisorCore
//
//  Pure-logic differ between two ordered id sequences. Returns the
//  index sets a view-based NSTableView (`performBatchUpdates`) needs
//  to animate the transition: which OLD rows to remove, which NEW row
//  positions to insert.
//
//  Why a custom differ instead of NSDiffableDataSource: chat row
//  arrays are append-heavy (streaming) with occasional tail-replace
//  (echo → real id swap) and infrequent prepend (load-earlier). The
//  pathologies of a generic LCS-style differ (O(N*M) on near-equal
//  arrays) don't fit. We exploit the chat shape:
//
//    1. Find the longest common PREFIX.
//    2. Find the longest common SUFFIX (without overlapping the prefix).
//    3. Everything between gets a flat remove + insert.
//
//  This is O(N+M) and correct for every pattern that arises in chat
//  (append, prepend, tail-replace, full-clear, /compact). The only
//  case where it's "suboptimal" is a true reorder mid-array — which
//  doesn't happen in chat, but if it did, we'd just re-render the
//  middle block, which is still correct.
//

import Foundation

public struct ChatRowDiff: Equatable, Sendable {
    /// Indices in the OLD array to remove. Apply in descending order
    /// to keep indices valid as you remove.
    public let removals: IndexSet
    /// Indices in the NEW array to insert. Apply in ascending order
    /// after the removals are applied.
    public let insertions: IndexSet

    public var isNoop: Bool { removals.isEmpty && insertions.isEmpty }

    /// Compute the diff. Both arrays should contain *stable, unique*
    /// row ids — duplicates inside a single array break the algorithm
    /// (and the chat pipeline already de-dupes upstream).
    public static func compute(old: [String], new: [String]) -> ChatRowDiff {
        // Common-prefix length.
        var prefix = 0
        let prefixCap = min(old.count, new.count)
        while prefix < prefixCap, old[prefix] == new[prefix] {
            prefix += 1
        }

        // Common-suffix length, bounded so it doesn't overlap the
        // already-counted prefix on either side.
        var suffix = 0
        let suffixCap = min(old.count - prefix, new.count - prefix)
        while suffix < suffixCap,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        // The middle band is what changed. Everything in old's middle
        // is removed; everything in new's middle is inserted.
        let oldMiddleStart = prefix
        let oldMiddleEnd = old.count - suffix
        let newMiddleStart = prefix
        let newMiddleEnd = new.count - suffix

        var removals = IndexSet()
        if oldMiddleStart < oldMiddleEnd {
            removals.insert(integersIn: oldMiddleStart..<oldMiddleEnd)
        }
        var insertions = IndexSet()
        if newMiddleStart < newMiddleEnd {
            insertions.insert(integersIn: newMiddleStart..<newMiddleEnd)
        }

        return ChatRowDiff(removals: removals, insertions: insertions)
    }
}
