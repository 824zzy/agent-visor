import Foundation

/// Opens `claude attach` in a new window of the running Ghostty. Launching a
/// second Ghostty instead (`open -n`) would take over the app's AppleScript,
/// so later tab focus would search the wrong instance's windows.
public enum ClaudeGhosttyAttachScript {
    public static func make(target: NativeHelperClaudeAttachTarget) -> String {
        let command = "\(shellQuote(target.executable)) attach \(shellQuote(target.jobId))"
        return """
        tell application "Ghostty"
            activate
            set attachCfg to new surface configuration
            set initial working directory of attachCfg to "\(AppleScriptEscaper.escape(target.cwd))"
            set command of attachCfg to "\(AppleScriptEscaper.escape(command))"
            new window with configuration attachCfg
            return "ok"
        end tell
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
