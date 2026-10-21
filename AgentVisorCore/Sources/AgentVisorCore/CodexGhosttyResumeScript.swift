import Foundation

/// Builds the exact Codex CLI resume launch accepted by the native helper.
/// Only validated references cross the wire; provider command text is never
/// supplied by the caller.
public enum CodexGhosttyResumeScript {
    public static func make(
        target: NativeHelperGhosttyResumeTarget,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let configRoot = target.configRoot ?? homeDirectory
        var commandParts = [
            "/usr/bin/env", "-i",
            "HOME=\(shellQuote(homeDirectory))",
            "PATH=/usr/bin:/bin",
            "TERM=xterm-256color",
            "CODEX_HOME=\(shellQuote(configRoot))",
            "AGENT_VISOR_RESUME_NONCE=\(shellQuote(target.nonce))",
            shellQuote(target.executable),
            "resume",
            shellQuote(target.sessionId),
            "--cd",
            shellQuote(target.cwd),
        ]
        if target.profileState == "present", let profile = target.profileRef {
            commandParts.append("--profile")
            commandParts.append(shellQuote(profile))
        }
        let command = commandParts.joined(separator: " ")
        return """
        (function () {
            var app = Application('com.mitchellh.ghostty');
            if (!app.running()) {
                return JSON.stringify({status: 'unavailable', reason: 'surface_unavailable'});
            }
            var created = false;
            try {
                var cfg = app.newSurfaceConfiguration();
                cfg.command = \(jsString(command));
                cfg.initialWorkingDirectory = \(jsString(target.cwd));
                cfg.initialInput = '';
                cfg.environmentVariables = ['ENV=/dev/null', 'BASH_ENV=/dev/null'];
                var window = app.newWindow({withConfiguration: cfg});
                created = true;
                var tab = window.selectedTab();
                var terminal = tab.focusedTerminal();
                var windowId = window.id();
                var tabId = tab.id();
                var terminalId = terminal.id();
                if (typeof windowId !== 'string' || !windowId || windowId.length > 128 ||
                    typeof tabId !== 'string' || !tabId || tabId.length > 128 ||
                    typeof terminalId !== 'string' || !terminalId || terminalId.length > 128) {
                    return JSON.stringify({status: 'uncertain'});
                }
                return JSON.stringify({status: 'created', windowId: windowId,
                    tabId: tabId, terminalId: terminalId});
            } catch (error) {
                return JSON.stringify({status: created ? 'uncertain' : 'unavailable',
                    reason: String(error)});
            }
        })()
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
