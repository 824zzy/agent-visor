import Foundation

/// Pure-logic helpers for selecting a specific iTerm2 session by TTY
/// without activating the iTerm2 app. iTerm2's `select` verb only
/// changes the internal active-session state — it does NOT raise the
/// app or switch macOS Space (see `feedback_terminal_activate.md`).
/// Combined with `CGEvent.postToPid`, this lets agent-visor deliver
/// a keystroke (e.g., Shift+Tab for mode cycling) to a specific iTerm2
/// pane silently.
public enum ITermSessionLocator {
    /// AppleScript that walks every window × tab × session and `select`s
    /// the one whose `tty` ends with `ttyName`. Returns "ok" on hit,
    /// "not-found" otherwise.
    ///
    /// Suffix-match is used because iTerm2's `tty` value is the absolute
    /// device path (e.g., "/dev/ttys012") while `SessionState.tty` may
    /// be stored as the bare name ("ttys012"). Callers strip the
    /// "/dev/" prefix before passing in.
    public static func selectScript(ttyName: String) -> String {
        let escaped = ttyName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(escaped)" then
                                select w
                                tell w to select t
                                tell t to select s
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """
    }

    /// Parse the select script's stdout. True only on the exact "ok"
    /// sentinel (trimmed); anything else — "not-found", AppleScript
    /// error message, empty string — is a miss.
    public static func parseSelectOutput(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// Normalize a SessionState.tty value (may be "ttys012" or
    /// "/dev/ttys012") to the bare device name the AppleScript
    /// suffix-match expects.
    public static func normalizeTTY(_ tty: String) -> String {
        if tty.hasPrefix("/dev/") { return String(tty.dropFirst(5)) }
        return tty
    }

    /// AppleScript that fetches the iTerm2 session whose `tty` ends with
    /// `ttyName` and returns its full buffer plus the visible viewport
    /// row count. Output shape:
    ///
    ///     <rows>\n<contents>
    ///
    /// where `rows` is `rows of session` (visible grid height) and
    /// `contents` is `contents of session` (full scrollback + visible).
    /// Callers slice the last `rows` lines off `contents` to recover
    /// the live viewport — necessary because iTerm2's `contents` and
    /// `text` properties both return scrollback-inclusive text, so
    /// just suffixing a fixed character window can lock onto a
    /// historical mode badge that has scrolled out of view (e.g.
    /// "⏵⏵ accept edits on" lingering after the user pressed
    /// shift+tab back to default mode).
    ///
    /// Returns "0\n" when no session matches.
    public static func contentsScript(ttyName: String) -> String {
        let escaped = ttyName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(escaped)" then
                                set r to (rows of s) as text
                                set c to (contents of s)
                                return r & linefeed & c
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "0" & linefeed
        end tell
        """
    }

    /// Decode the `<rows>\n<contents>` envelope produced by
    /// `contentsScript`. Returns the live viewport (last `rows` lines
    /// of the buffer) so the caller never sees scrollback. Nil for
    /// "no session matched" or empty pane.
    ///
    /// We slice by lines, not characters, because iTerm2 reports
    /// `rows` in grid terms — taking the last N lines mirrors what
    /// the user actually sees on screen. Soft-wrapped lines that span
    /// multiple grid rows count as one line here, which means the
    /// returned slice can be slightly *taller* than the viewport in
    /// pathological cases; that is fine — the mode badge sits on its
    /// own short line and the parser is tail-anchored.
    public static func parseContentsOutput(_ raw: String) -> String? {
        let stripped = raw.replacingOccurrences(of: "\r", with: "")
        if let nlIdx = stripped.firstIndex(of: "\n") {
            let header = stripped[stripped.startIndex..<nlIdx]
                .trimmingCharacters(in: .whitespaces)
            if let rows = Int(header) {
                // New envelope. rows == 0 is the "no session matched"
                // sentinel: empty body intentional, nil for the caller.
                if rows == 0 { return nil }
                let body = stripped[stripped.index(after: nlIdx)...]
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedBody.isEmpty { return nil }
                let lines = trimmedBody.split(separator: "\n", omittingEmptySubsequences: false)
                return lines.suffix(rows).joined(separator: "\n")
            }
        }
        // Legacy fallback (old script, or osascript wrapped the output
        // unexpectedly): return the trimmed body so this remains a
        // safe upgrade path.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AppleScript that delivers `payload` to the iTerm2 session matching
    /// `ttyName` as a bracketed paste — wraps the text in CSI 200~ /
    /// 201~ markers and writes through iTerm2's raw `write text` channel
    /// (no auto-newline, no submit). Claude Code's DECSET 2004 paste
    /// handler reads the payload as a single paste event, which is how
    /// it recognizes "/tmp/av-…png" as an image attachment.
    public static func bracketedPasteScript(ttyName: String, payload: String) -> String {
        let escapedTTY = ttyName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPayload = payload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(escapedTTY)" then
                                tell s
                                    write text ((ASCII character 27) & "[200~" & "\(escapedPayload)" & (ASCII character 27) & "[201~") newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """
    }
}
