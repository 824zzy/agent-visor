import Foundation

/// Shared bounded Ghostty surface creation and readback wrapper.
/// Provider scripts supply their validated command text and working directory.
enum GhosttyResumeScriptSupport {
    static func make(command: String, workingDirectory: String) -> String {
        """
        (function () {
            var app = Application('com.mitchellh.ghostty');
            if (!app.running()) {
                return JSON.stringify({status: 'pre_creation_failed', reason: 'ghostty_not_running'});
            }
            var created = false;
            try {
                var cfg = app.newSurfaceConfiguration();
                cfg.command = \(jsString(command));
                cfg.initialWorkingDirectory = \(jsString(workingDirectory));
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

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
