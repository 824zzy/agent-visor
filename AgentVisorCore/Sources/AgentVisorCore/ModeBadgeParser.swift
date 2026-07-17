import Foundation

public enum ModeBadgeParser {
    /// Mode badges shown by Claude Code's TUI in the status line. Only the
    /// chevron + first word is matched: terminal AX rendering can truncate
    /// the badge mid-word at the right edge of the viewport, so longer
    /// needles ("auto mode on") would miss in the wild.
    private static let patterns: [(needle: String, mode: String)] = [
        ("⏵⏵ bypass", "bypassPermissions"),
        ("⏵⏵ accept", "acceptEdits"),
        ("⏸ plan",    "plan"),
        ("⏵⏵ auto",   "auto"),
    ]

    /// Glyphs from Claude Code's prompt area. Their presence means the
    /// TUI is rendering its prompt, so absence of any badge implies
    /// default mode (Claude Code shows no explicit badge for default).
    ///
    /// `❯` is the chevron Claude Code uses as its prompt cursor in the
    /// post-redesign TUI; `─` covers the horizontal rules that bracket
    /// the input row. The legacy box-drawing corners (`╭ ╮ ╰ ╯`) and
    /// `│` remain because older Claude Code versions still in the wild
    /// render the prompt with a full box.
    private static let tuiMarkers: Set<Character> = ["│", "╭", "╮", "╰", "╯", "❯", "─"]

    /// Match window: only this many trailing chars are considered for both
    /// badge match and TUI marker check. Old scrollback can mention any
    /// historical mode; only the active status line at the tail matters.
    private static let tailWindow = 1024

    public static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(trimmed.suffix(tailWindow))
        if let mode = matchBadge(in: tail) { return mode }
        return tail.contains(where: { tuiMarkers.contains($0) }) ? "default" : nil
    }

    private static func matchBadge(in text: String) -> String? {
        var best: (lowerBound: String.Index, mode: String)?
        for (needle, mode) in patterns {
            guard let range = text.range(of: needle, options: .backwards) else { continue }
            if best == nil || range.lowerBound > best!.lowerBound {
                best = (range.lowerBound, mode)
            }
        }
        return best?.mode
    }
}
