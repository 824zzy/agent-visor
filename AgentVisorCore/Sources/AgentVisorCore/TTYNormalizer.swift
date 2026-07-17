import Foundation

/// Normalizes the raw `tty` field returned by `ps -o tty=` into either a
/// concrete TTY name or `nil` (meaning "no controlling terminal").
///
/// macOS `ps` returns `??` when a process has no controlling terminal —
/// the canonical case is Cursor's claude-code extension, which spawns
/// `claude` as a stdio child of `Cursor Helper (Plugin)` with no PTY
/// in the parent chain. Other sources of `??` / empty: launchd-spawned
/// headless runs, subprocess Popens with no `setsid`, certain CI images.
///
/// `SessionState.tty` is optional, and downstream Ghostty/iTerm2 /
/// tmux integration paths all guard on `session.tty != nil`. Centralizing
/// the conversion here keeps that contract explicit and unit-testable.
public enum TTYNormalizer {
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "??" { return nil }
        return trimmed
    }
}
