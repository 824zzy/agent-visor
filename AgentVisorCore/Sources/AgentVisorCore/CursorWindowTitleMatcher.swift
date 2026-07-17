import Foundation

/// Decides whether any of Cursor's open AX-window titles plausibly
/// hosts a given workspace folder. The pill-click handler uses this
/// as a gate before invoking LaunchServices `open -a Cursor <cwd>` —
/// if no match exists, the click MUST NOT auto-open a new window
/// because Cursor's "open document" handler creates one when none
/// matches.
///
/// Cursor titles take a few canonical shapes:
///   "<workspace>"
///   "<file> — <workspace>"
///   "<file1>, <file2> — <workspace>"
///   "<workspace>, <peer-workspace>"        // multi-root window
///   "<file> — <workspace>, <peer-workspace>"
///
/// Match rule: tokenize each title on `, ` and ` — ` and check
/// whether any resulting token equals the workspace folder's last
/// path component (case-insensitive). Token-level equality avoids
/// substring false-positives like ".claude" matching "agent-visor".
public enum CursorWindowTitleMatcher {
    public static func hasMatchingWindow(
        workspaceFolder: String,
        cursorWindowTitles: [String]
    ) -> Bool {
        let folderName = (workspaceFolder as NSString).lastPathComponent
        guard !folderName.isEmpty, folderName != "/" else { return false }
        let target = folderName.lowercased()
        for title in cursorWindowTitles {
            for token in tokens(in: title) where token == target {
                return true
            }
        }
        return false
    }

    /// Split a Cursor window title into the comma- and em-dash-separated
    /// tokens it's built from, lowercased and trimmed.
    private static func tokens(in title: String) -> [String] {
        let lowered = title.lowercased()
        // Two-step split: first by " — " (em dash with spaces, the
        // file/workspace separator), then by ", " (peer separator).
        var pieces: [String] = []
        for half in lowered.components(separatedBy: " — ") {
            for piece in half.components(separatedBy: ", ") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    pieces.append(trimmed)
                }
            }
        }
        return pieces
    }
}
