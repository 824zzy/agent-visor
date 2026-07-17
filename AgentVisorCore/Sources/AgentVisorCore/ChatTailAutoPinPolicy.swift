//
//  ChatTailAutoPinPolicy.swift
//  AgentVisorCore
//
//  Pure-logic decisions about whether to auto-scroll the chat to the
//  bottom on row insertion or streaming text growth.
//
//  This replaces the implicit `defaultScrollAnchor(.bottom)` +
//  `proxy.scrollTo("__bottom__")` machinery from the SwiftUI
//  ScrollView path. With AppKit's NSTableView, the view layer has to
//  decide explicitly: when a new row arrives, do we yank the user
//  down to the bottom (because they were at the bottom and want to
//  follow the conversation), or do we leave them parked (because
//  they scrolled up to read older context and would be furious if we
//  yanked them back)?
//
//  The classic chat-app rule: pin unless the user is meaningfully
//  scrolled up. "Meaningfully" = more than a small forgiveness band
//  to absorb momentum-scroll overshoot.
//

import Foundation

public enum ChatTailAutoPinPolicy {
    /// Pixels of slack we tolerate as "still at-bottom." Slack and
    /// Messages both use ~80–120pt; we sit in that band. The exact
    /// number isn't load-bearing — anything in this range feels right.
    public static let defaultNearBottomThreshold: CGFloat = 80

    /// True if the viewport is "close enough" to the document bottom
    /// that we should treat the user as wanting to follow new content.
    public static func isNearBottom(
        distanceFromBottom: CGFloat,
        threshold: CGFloat = defaultNearBottomThreshold
    ) -> Bool {
        distanceFromBottom <= threshold
    }

    /// Decide whether to auto-scroll the table to the new last row
    /// after applying a diff that inserted rows.
    ///
    /// - `distanceFromBottom`: pixels from the current scroll bottom
    ///   to the document bottom BEFORE the insert was animated in.
    /// - `insertedAtTail`: whether the insert affected the last row
    ///   region (load-earlier inserts at head and must NEVER pin).
    public static func shouldAutoPinOnInsert(
        distanceFromBottom: CGFloat,
        threshold: CGFloat = defaultNearBottomThreshold,
        insertedAtTail: Bool
    ) -> Bool {
        guard insertedAtTail else { return false }
        return isNearBottom(distanceFromBottom: distanceFromBottom, threshold: threshold)
    }

    /// Decide whether to nudge the bottom on a streaming text-growth
    /// tick (no row count change, last row got taller). Same predicate
    /// as `isNearBottom`, separated for readability at the call site.
    public static func shouldStreamPin(
        distanceFromBottom: CGFloat,
        threshold: CGFloat = defaultNearBottomThreshold
    ) -> Bool {
        isNearBottom(distanceFromBottom: distanceFromBottom, threshold: threshold)
    }
}
