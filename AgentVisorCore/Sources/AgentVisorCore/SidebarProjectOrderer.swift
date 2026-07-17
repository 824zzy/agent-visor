import Foundation

/// Layers a user's manual project order on top of the natural
/// (recency-derived) project order for the window-mode sidebar.
///
/// The sidebar groups sessions by project (cwd's last component). By
/// default projects sort by their most-recent activity, but the user can
/// drag a project header to pin a custom order. This orderer is the pure
/// merge of "what the user dragged" with "what's actually present right
/// now":
///
///   - Saved keys that still exist keep their saved relative order, first.
///   - Keys present but never dragged (new projects) follow, in their
///     natural order as passed by the caller.
///   - Saved keys that no longer exist are dropped (a closed project
///     shouldn't leave a hole or resurrect if it returns mid-list).
///
/// Pure / value-in-value-out so it's unit-testable without UI or storage.
/// "Needs attention" and "Other" are NOT projects and are positioned by
/// the caller (pinned top/bottom); this orderer only sequences the
/// project groups between them.
public enum SidebarProjectOrderer {
    /// Final project-key order: saved order (filtered to live keys) first,
    /// then any live keys not in the saved order, in `naturalOrder`.
    ///
    /// - Parameters:
    ///   - naturalOrder: project keys in their default order (recency),
    ///     as the grouper would produce without user intervention.
    ///   - manualOrder: the user's saved drag order (may contain stale
    ///     keys for projects that have since closed, and may omit keys
    ///     for projects opened since the last drag).
    public static func order(naturalOrder: [String], manualOrder: [String]) -> [String] {
        let live = Set(naturalOrder)
        var result: [String] = []
        var placed = Set<String>()

        // 1. Saved order, restricted to keys that still exist.
        for key in manualOrder where live.contains(key) && !placed.contains(key) {
            result.append(key)
            placed.insert(key)
        }
        // 2. Everything else, in natural order (new/never-dragged projects).
        for key in naturalOrder where !placed.contains(key) {
            result.append(key)
            placed.insert(key)
        }
        return result
    }

    /// Apply a drag: move `movedKey` so it lands immediately before
    /// `targetKey` in `currentOrder`. If `targetKey` is nil (dropped past
    /// the end / onto empty space), `movedKey` goes last. No-ops cleanly
    /// when keys are missing or moved onto itself.
    public static func reordered(
        currentOrder: [String],
        movedKey: String,
        before targetKey: String?
    ) -> [String] {
        guard currentOrder.contains(movedKey) else { return currentOrder }
        if let targetKey, targetKey == movedKey { return currentOrder }

        var working = currentOrder.filter { $0 != movedKey }
        if let targetKey, let idx = working.firstIndex(of: targetKey) {
            working.insert(movedKey, at: idx)
        } else {
            working.append(movedKey)
        }
        return working
    }
}
