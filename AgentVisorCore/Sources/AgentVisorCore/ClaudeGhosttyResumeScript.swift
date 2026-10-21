import Foundation

/// Builds the one structured Claude resume launch accepted by the native
/// helper. The caller supplies validated fields; this type never accepts an
/// arbitrary shell command or provider environment.
public enum ClaudeGhosttyResumeScript {
    public static func make(
        target: NativeHelperGhosttyResumeTarget,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let sources = target.settingSources?.joined(separator: ",")
        var commandParts = [
            "/usr/bin/env", "-i",
            "HOME=\(shellQuote(homeDirectory))",
            "PATH=/usr/bin:/bin",
            "TERM=xterm-256color",
            "AGENT_VISOR_RESUME_NONCE=\(shellQuote(target.nonce))",
        ]
        if let configRoot = target.configRoot {
            commandParts.append("CLAUDE_CONFIG_DIR=\(shellQuote(configRoot))")
        }
        commandParts.append(shellQuote(target.executable))
        if let settingsFile = target.settingsFile {
            commandParts.append("--settings")
            commandParts.append(shellQuote(settingsFile))
        }
        if let sources {
            commandParts.append("--setting-sources")
            commandParts.append(shellQuote(sources))
        }
        commandParts.append("--resume")
        commandParts.append(shellQuote(target.sessionId))
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
