import Foundation

/// Picks the editor window that best matches a Claude Code session's
/// project name from a list of window titles. Pure-Swift logic so it can
/// be unit-tested without driving the Accessibility API.
///
/// VS Code and Cursor share a title format like
/// `<filename> — <workspace folder>` (em dash separator), or just
/// `<workspace folder>` when no file is open. The matcher takes the
/// last em-dash segment as the strongest signal.
public enum EditorWindowMatcher {
    /// Returns the index of the title that best identifies the session's
    /// workspace, or nil if no plausible match exists.
    ///
    /// Matching priority (case-insensitive throughout):
    ///   1. Any " — "-separated segment equals `projectName`.
    ///   2. Title contains `projectName` as a whole word.
    ///
    /// Returns the first match in `titles` to keep behavior deterministic
    /// when multiple windows have the same workspace open.
    public static func bestMatch(titles: [String], projectName: String) -> Int? {
        let target = projectName.lowercased()
        guard !target.isEmpty else { return nil }
        for (i, title) in titles.enumerated() {
            let segments = title.lowercased().components(separatedBy: " — ")
            if segments.contains(target) { return i }
        }
        return nil
    }
}
