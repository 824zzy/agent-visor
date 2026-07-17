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
