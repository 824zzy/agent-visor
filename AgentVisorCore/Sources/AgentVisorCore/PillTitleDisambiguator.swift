import Foundation

/// Computes per-item disambiguation suffixes for status pills whose
/// `title` collides with another pill in the same list.
///
/// Motivating case: Cursor's claude-code extension routinely spawns
/// multiple claude sessions in the same workspace (cwd). Every pill
/// falls back to `projectName` until a user message lands, so the user
/// can't tell them apart in the menu bar. This helper returns a
/// `[id: suffix]` map keyed by sessionId, where `suffix` is the first
/// four characters of the id — appended to the pill label only on
/// collision. Sessions with unique titles are absent from the result so
/// the common case (one session per workspace) renders untouched.
public enum PillTitleDisambiguator {

    public struct Item {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Returns `[id: suffix]` for every item whose `title` is shared
    /// with at least one other item in `items`. The suffix is the first
    /// four characters of `id`. Items with unique titles are absent.
    public static func suffixes(for items: [Item]) -> [String: String] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.title, default: 0] += 1
        }
        var result: [String: String] = [:]
        for item in items where (counts[item.title] ?? 0) > 1 {
            result[item.id] = String(item.id.prefix(4))
        }
        return result
    }
}
