import Foundation

/// Pulls the most-recent assistant text block out of Claude Code's TUI
/// scrollback, used to bridge the JSONL buffering gap during a pending
/// AskUserQuestion. Claude Code holds an assistant message's text in
/// memory until its trailing tool_use resolves, so for the window
/// between "assistant finished generating analysis" and "user answered
/// the question," the text is only visible on the terminal — not in
/// the JSONL agent-visor reads from. This parser reads the terminal
/// AX text, finds the assistant content immediately preceding the
/// active question form, and lets `SessionStore` inject it as a
/// synthetic chat item until JSONL catches up.
///
/// TUI markers we anchor to:
///   `●` (U+25CF) — leader for each assistant text block. Claude Code
///   prefixes each top-level assistant text segment with this glyph.
///   `□` (U+25A1) — leader for the question form header. Marks the
///   active AskUserQuestion's location in the buffer.
public enum TerminalScrollbackParser {
    private static let assistantLeader: Character = "\u{25CF}" // ●
    private static let questionLeader: Character = "\u{25A1}"  // □

    /// Returns the body of the last `●` assistant block that appears
    /// immediately before the most recent `□` question marker. Returns
    /// nil if there is no question marker or no preceding assistant
    /// block in the buffer.
    public static func lastAssistantBlockBeforeQuestion(in tuiText: String) -> String? {
        guard let questionIdx = lastLineStartIndex(of: questionLeader, in: tuiText) else { return nil }
        guard let leaderIdx = lastLineStartIndex(of: assistantLeader, in: tuiText, endingBefore: questionIdx) else { return nil }
        let blockRange = tuiText.index(after: leaderIdx)..<questionIdx
        let body = String(tuiText[blockRange])
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the latest index where `marker` appears at the start of
    /// a line (preceded by `\n` or at the start of the string). Optional
    /// `endingBefore` upper-bounds the search so we can find the leader
    /// strictly before the question marker. Returns nil if no
    /// line-start occurrence exists in the searched range.
    private static func lastLineStartIndex(
        of marker: Character,
        in text: String,
        endingBefore: String.Index? = nil
    ) -> String.Index? {
        let upperBound = endingBefore ?? text.endIndex
        var cursor = text.startIndex
        var lastHit: String.Index?
        while cursor < upperBound {
            if text[cursor] == marker {
                let isLineStart = cursor == text.startIndex
                    || text[text.index(before: cursor)] == "\n"
                if isLineStart {
                    lastHit = cursor
                }
            }
            cursor = text.index(after: cursor)
        }
        return lastHit
    }
}
