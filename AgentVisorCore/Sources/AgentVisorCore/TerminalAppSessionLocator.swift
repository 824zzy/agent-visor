import Foundation

public enum TerminalAppSessionLocator {
    public static func focusScript(ttyName: String) -> String {
        let escapedTTY = escape(ttyName)
        return targetScript(ttyName: escapedTTY, action: """
        set selected of targetTab to true
        set frontmost of targetWindow to true
        activate
        delay 0.05
        if selected of targetTab and (tty of targetTab ends with "\(escapedTTY)") then
            return "ok"
        end if
        return "focus-mismatch"
        """)
    }

    public static func sendTextScript(ttyName: String, text: String) -> String {
        targetScript(ttyName: escape(ttyName), action: """
        do script "\(escape(text))" in targetTab
        return "ok"
        """)
    }

    /// Selects the exact Terminal.app tab before posting Escape through the
    /// host's verified key-event route.  Terminal.app has no supported
    /// per-tab `send key` AppleScript verb; System Events is therefore used
    /// only after the TTY-bound tab is selected and activated.  Callers must
    /// revalidate the provider process identity immediately before running
    /// this script and treat any non-`ok` result as a failed cancellation.
    public static func escapeScript(ttyName: String) -> String {
        let escapedTTY = escape(ttyName)
        return """
        tell application "Terminal"
            set targetWindow to missing value
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t ends with "\(escapedTTY)" then
                            set targetWindow to w
                            set targetTab to t
                        end if
                    end try
                end repeat
            end repeat
            if targetTab is missing value then return "not-found"
            set selected of targetTab to true
            set frontmost of targetWindow to true
            activate
        end tell
        tell application "System Events"
            tell process "Terminal"
                key code 53
            end tell
        end tell
        return "ok"
        """
    }

    /// Clears a bounded number of characters from the selected Terminal.app
    /// tab using the same exact TTY selection and System Events route as
    /// `escapeScript`. Keeping this host-specific avoids sending a
    /// Terminal.app cancellation cleanup through Ghostty by accident.
    public static func backspaceScript(ttyName: String, count: Int) -> String {
        let escapedTTY = escape(ttyName)
        let boundedCount = min(max(count, 0), 4_096)
        return """
        tell application "Terminal"
            set targetWindow to missing value
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t ends with "\(escapedTTY)" then
                            set targetWindow to w
                            set targetTab to t
                        end if
                    end try
                end repeat
            end repeat
            if targetTab is missing value then return "not-found"
            set selected of targetTab to true
            set frontmost of targetWindow to true
            activate
        end tell
        tell application "System Events"
            tell process "Terminal"
                repeat \(boundedCount) times
                    key code 51
                end repeat
            end tell
        end tell
        return "ok"
        """
    }

    private static func targetScript(ttyName: String, action: String) -> String {
        """
        tell application "Terminal"
            set targetWindow to missing value
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t ends with "\(ttyName)" then
                            set targetWindow to w
                            set targetTab to t
                        end if
                    end try
                end repeat
            end repeat
            if targetTab is missing value then return "not-found"
            \(action)
        end tell
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
