import Foundation

/// Opens `claude attach` in a new window of the running Ghostty. Launching a
/// second Ghostty instead (`open -n`) would take over the app's AppleScript,
/// so later tab focus would search the wrong instance's windows.
public enum ClaudeGhosttyAttachScript {
    public static func make(target: NativeHelperClaudeAttachTarget) -> String {
        // Applies only to this display client, including its overview. The
        // command-line setting overrides a user's title-suppressed profile.
        let settings = #"{"env":{"CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"0"}}"#
        let command = "/usr/bin/env CLAUDE_CODE_DISABLE_TERMINAL_TITLE=0 \(shellQuote(target.executable)) --settings \(shellQuote(settings)) attach \(shellQuote(target.jobId))"
        return """
        tell application "Ghostty"
            activate
            set attachCfg to new surface configuration
            set initial working directory of attachCfg to "\(AppleScriptEscaper.escape(target.cwd))"
            set command of attachCfg to "\(AppleScriptEscaper.escape(command))"
            set wait after command of attachCfg to false
            set attachWindow to new window with configuration attachCfg
            return id of focused terminal of selected tab of attachWindow
        end tell
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
