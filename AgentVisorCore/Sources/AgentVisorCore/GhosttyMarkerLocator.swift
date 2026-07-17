import Foundation

/// Pure-logic building blocks for locating a specific Ghostty terminal by
/// writing a unique OSC 7 marker to its TTY and asking Ghostty's AppleScript
/// layer which terminal has that marker as its working directory.
///
/// This avoids the AXText-substring scoring used by `GhosttyModeProbe`,
/// which is fragile when multiple panes share a working directory (e.g.,
/// two worktrees of the same repo) or when one pane's scrollback contains
/// another pane's cwd.
///
/// The impure parts (writing to TTY, invoking osascript, translating
/// AppleScript indices to AX elements) live host-side. This type only
/// provides the deterministic, testable pieces.
public enum GhosttyMarkerLocator {
    /// A located terminal, addressed by Ghostty's AppleScript 1-based
    /// `(window, terminal)` index pair.
    public struct Location: Equatable, Sendable {
        public let windowIndex: Int
        public let terminalIndex: Int
        public init(windowIndex: Int, terminalIndex: Int) {
            self.windowIndex = windowIndex
            self.terminalIndex = terminalIndex
        }
    }

    /// Produce a unique marker path. Format: `/tmp/av-cycle-<random>`.
    /// Two calls within the same process must produce different markers
    /// (cycles can overlap if the cooldown were ever removed). Caller
    /// can pass a seed for deterministic tests.
    public static func makeMarker(seed: UInt64? = nil) -> String {
        let value: UInt64
        if let seed { value = seed }
        else { value = UInt64.random(in: 100_000_000 ... 999_999_999) }
        return "/tmp/av-cycle-\(value)"
    }

    /// OSC 7 escape sequence Ghostty consumes to update a terminal's
    /// internal `working directory` property. Writing this to the
    /// session's TTY changes ONLY that terminal's cwd-as-seen-by-Ghostty,
    /// not the actual cwd of the running process.
    public static func osc7Sequence(cwd: String, host: String = "localhost") -> String {
        "\u{1b}]7;file://\(host)\(cwd)\u{07}"
    }

    /// AppleScript that walks every Ghostty window and terminal, looking
    /// for the one whose `working directory` equals `marker`. Output:
    ///   "<w>,<t>"     when a single terminal matches
    ///   "not-found"   when no terminal matches
    public static func locatorScript(marker: String) -> String {
        let escaped = marker
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(escaped)" then
                            return (w as string) & "," & (i as string)
                        end if
                    end try
                end repeat
            end repeat
            return "not-found"
        end tell
        """
    }

    public static func focusScript(marker: String) -> String {
        let escaped = marker
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Ghostty"
            set targetId to missing value
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(escaped)" then
                            set targetId to id of t
                        end if
                    end try
                end repeat
            end repeat
            if targetId is missing value then return "not-found"
            focus (terminal id targetId)
            delay 0.05
            try
                set focusedId to id of focused terminal of selected tab of front window
                if focusedId is targetId then return "ok"
            end try
            return "focus-mismatch"
        end tell
        """
    }

    /// Parse the locator script's stdout. Trims whitespace; accepts only
    /// the strict `<w>,<t>` format with two positive integers.
    public static func parseLocatorOutput(_ raw: String) -> Location? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not-found" else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let w = Int(parts[0]), w > 0,
              let t = Int(parts[1]), t > 0
        else { return nil }
        return Location(windowIndex: w, terminalIndex: t)
    }
}
