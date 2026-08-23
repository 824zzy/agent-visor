import AgentVisorCore
import AppKit
import Foundation

final class NativeTerminalController {
    func focus(_ target: NativeHelperTerminalTarget) -> Bool {
        switch target.application {
        case .ghostty:
            return withMarker(target) { marker in
                let escaped = AppleScriptEscaper.escape(marker)
                return run("""
                tell application "Ghostty"
                    repeat with w from 1 to (count windows)
                        repeat with i from 1 to (count every terminal of window w)
                            set t to terminal i of window w
                            try
                                if working directory of t is "\(escaped)" then
                                    focus t
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                    return "not-found"
                end tell
                """) == "ok"
            }
        case .iTerm2:
            return run(iTermScript(target: target, body: "select\nactivate")) == "ok"
        case .terminal:
            return run(terminalScript(target: target)) == "ok"
        }
    }

    func send(_ text: String, to target: NativeHelperTerminalTarget, submit: Bool) -> Bool {
        switch target.application {
        case .ghostty:
            let escaped = AppleScriptEscaper.escape(text)
            return withMarker(target) { marker in
                let enter = submit ? "delay 0.12\n                                    send key \"enter\" to t" : ""
                return run("""
                tell application "Ghostty"
                    repeat with w from 1 to (count windows)
                        repeat with i from 1 to (count every terminal of window w)
                            set t to terminal i of window w
                            try
                                if working directory of t is "\(AppleScriptEscaper.escape(marker))" then
                                    input text "\(escaped)" to t
                                    \(enter)
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                    return "not-found"
                end tell
                """) == "ok"
            }
        case .iTerm2:
            let escaped = AppleScriptEscaper.escape(text)
            let write = submit
                ? "write text \"\(escaped)\""
                : "write text ((ASCII character 27) & \"[200~\" & \"\(escaped)\" & (ASCII character 27) & \"[201~\") newline no"
            return run(iTermScript(target: target, body: write)) == "ok"
        case .terminal:
            guard focus(target) else { return false }
            usleep(50_000)
            guard postText(text) else { return false }
            if submit { postKey(36) }
            return true
        }
    }

    private func withMarker(
        _ target: NativeHelperTerminalTarget,
        action: (String) -> Bool
    ) -> Bool {
        let marker = GhosttyMarkerLocator.makeMarker()
        let ttyPath = target.tty.hasPrefix("/dev/") ? target.tty : "/dev/\(target.tty)"
        guard write(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath) else {
            return false
        }
        usleep(100_000)
        let result = action(marker)
        let restored = write(GhosttyMarkerLocator.osc7Sequence(cwd: target.cwd), to: ttyPath)
        return result && restored
    }

    private func iTermScript(target: NativeHelperTerminalTarget, body: String) -> String {
        let tty = AppleScriptEscaper.escape(normalizedTTY(target.tty))
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            tell s
                                \(body)
                            end tell
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """
    }

    private func terminalScript(target: NativeHelperTerminalTarget) -> String {
        let tty = AppleScriptEscaper.escape(normalizedTTY(target.tty))
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            return "not-found"
        end tell
        """
    }

    private func normalizedTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    private func write(_ text: String, to path: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return false }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    private func run(_ source: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return "" }
        return result?.stringValue ?? ""
    }

    private func postText(_ text: String) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        let units = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(_ key: CGKeyCode) {
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
