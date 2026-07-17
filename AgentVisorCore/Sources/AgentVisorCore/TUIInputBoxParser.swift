import Foundation

/// Extracts the user-typed content from claude-code's TUI input box —
/// the boxed region drawn with `╭ │ ╰` borders that holds the next
/// prompt while the user is typing. Used by the clear-before-send path
/// so the caller can size a backspace burst to whatever leftover text
/// is sitting in the box (commonly: claude-code's REPL auto-restored
/// the just-canceled prompt after a Ctrl+C and the cancel-clear's race
/// with the next send left the buffer dirty).
///
/// Return contract:
///   - `nil` → no usable input box found (no opener, no closer, or
///     truncated buffer). Callers should skip the clear and proceed
///     with the raw send rather than guess at a backspace count.
///   - `""`  → input box found, content is empty. No clearing needed.
///   - any other string → backspace this many chars, then send.
public enum TUIInputBoxParser {

    private static let topBorder: Character = "\u{256D}"      // ╭
    private static let bottomBorder: Character = "\u{2570}"   // ╰
    private static let leftBorder: Character = "\u{2502}"     // │

    public static func currentInput(in scrollback: String) -> String? {
        // Find the LAST `╭` that has a matching `╰` after it. Anything
        // older in the scrollback is stale TUI history we don't care
        // about; an unclosed `╭` is a torn buffer we can't trust.
        let lines = scrollback.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Walk from the bottom up looking for the most recent `╰`,
        // then walk further up for its matching `╭`. The closer always
        // appears below its opener in a well-formed box.
        guard let closerIdx = lines.lastIndex(where: { $0.contains(bottomBorder) }) else {
            return nil
        }
        // Search above the closer for the most recent opener. If we
        // find another closer before the opener, that closer belongs
        // to an even older box — bail and use the closer we already
        // have (its matching opener might still be above).
        var openerIdx: Int? = nil
        var i = closerIdx - 1
        while i >= 0 {
            if lines[i].contains(topBorder) {
                openerIdx = i
                break
            }
            i -= 1
        }
        guard let opener = openerIdx, opener < closerIdx else {
            return nil
        }

        // Collect content lines between opener and closer. Each line
        // should start with `│`; any line that doesn't is a malformed
        // boundary — be lenient and skip those.
        let contentLines = Array(lines[(opener + 1)..<closerIdx])
        var extracted: [String] = []
        for raw in contentLines {
            guard let stripped = stripBorderAndPrompt(raw) else { continue }
            extracted.append(stripped)
        }
        // Box exists but no content lines extracted → empty content.
        // Box exists, content extracted → join with newlines.
        return extracted.joined(separator: "\n")
    }

    /// Claude-code's TUI lays the prompt arrow at a fixed offset from
    /// the left border: `│` (border) + space + `>` + space = 4 chars
    /// before the user content. Continuation lines occupy the same
    /// column with `│   ` (border + 3 spaces). Stripping the first 3
    /// chars after the left border canonicalizes both cases without
    /// having to special-case prompt vs. continuation rows.
    private static let promptSlotWidth = 3

    /// Strip the `│` borders, prompt slot, and right-edge padding from
    /// one row of the input box. Returns nil when the line isn't a
    /// box-content row (no matching `│ ... │`).
    private static func stripBorderAndPrompt(_ line: String) -> String? {
        guard let leftIdx = line.firstIndex(of: leftBorder) else { return nil }
        let afterLeft = line.index(after: leftIdx)
        guard let rightIdx = line[afterLeft...].firstIndex(of: leftBorder) else {
            return nil
        }

        var inner = String(line[afterLeft..<rightIdx])

        // Drop the prompt-slot prefix: ` > ` on the first content row,
        // `   ` on continuation rows. Both are 3 chars wide. If the
        // inner region is narrower than the prompt slot, treat it as
        // empty (degenerate box).
        if inner.count >= Self.promptSlotWidth {
            inner = String(inner.dropFirst(Self.promptSlotWidth))
        } else {
            return ""
        }

        // Trim only trailing whitespace — leading spaces inside the
        // post-prompt region belong to the user.
        while let last = inner.last, last == " " {
            inner.removeLast()
        }
        return inner
    }
}
