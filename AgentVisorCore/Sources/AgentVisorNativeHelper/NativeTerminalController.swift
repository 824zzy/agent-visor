import AgentVisorCore
import AppKit
import Darwin
import Foundation

public final class NativeTerminalController {
    public typealias KeyPoster = (CGKeyCode) -> Bool
    public typealias TargetVerifier = (NativeHelperTerminalTarget) -> Bool
    public typealias PermissionModePoster = (NativeHelperTerminalTarget) -> Bool

    private let keyPoster: KeyPoster
    private let focusOverride: ((NativeHelperTerminalTarget) -> Bool)?
    private let targetVerifier: TargetVerifier
    private let permissionModePoster: PermissionModePoster?

    public init(
        keyPoster: @escaping KeyPoster = NativeTerminalController.postKey,
        focusOverride: ((NativeHelperTerminalTarget) -> Bool)? = nil,
        targetVerifier: @escaping TargetVerifier = NativeTerminalController.liveTargetMatches,
        permissionModePoster: PermissionModePoster? = nil
    ) {
        self.keyPoster = keyPoster
        self.focusOverride = focusOverride
        self.targetVerifier = targetVerifier
        self.permissionModePoster = permissionModePoster
    }

    public func focus(_ target: NativeHelperTerminalTarget) -> Bool {
        guard targetVerifier(target) else { return false }
        if let focusOverride { return focusOverride(target) }
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
            guard targetVerifier(target) else { return false }
            return run(iTermScript(target: target, body: "select\nactivate")) == "ok"
        case .terminal:
            return run(terminalScript(target: target)) == "ok"
        }
    }

    public func send(_ text: String, to target: NativeHelperTerminalTarget, submit: Bool) -> Bool {
        // Preflight before constructing or executing any AppleScript/PTY
        // write. This keeps an over-limit request atomic: callers receive a
        // bounded send failure and can recover the exact composer draft,
        // rather than leaving a partially pasted prompt in the terminal.
        guard text.utf8.count <= NativeHelperWireLimits.maxTerminalTextBytes else {
            return false
        }
        guard targetVerifier(target) else { return false }
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
            guard targetVerifier(target) else { return false }
            return run(iTermScript(target: target, body: write)) == "ok"
        case .terminal:
            guard focus(target) else { return false }
            usleep(50_000)
            guard targetVerifier(target) else { return false }
            guard postText(text) else { return false }
            if submit {
                // Process identity can change while the text event is being
                // delivered. Revalidate before the separate Enter action so
                // a reused PID/TTY cannot receive the submit key.
                guard targetVerifier(target) else { return false }
                return keyPoster(36)
            }
            return true
        }
    }

    /// Send the provider's native cancel key to the exact terminal target.
    /// Ghostty and iTerm2 need a real named/raw Escape input. Terminal.app
    /// needs an escaped key event after its matching tab is focused.
    public func cancel(_ target: NativeHelperTerminalTarget) -> Bool {
        guard targetVerifier(target) else { return false }
        switch target.application {
        case .ghostty:
            return withMarker(target) { marker in
                run("""
                tell application "Ghostty"
                    repeat with w from 1 to (count windows)
                        repeat with i from 1 to (count every terminal of window w)
                            set t to terminal i of window w
                            try
                                if working directory of t is "\(AppleScriptEscaper.escape(marker))" then
                                    send key "escape" to t
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
            guard targetVerifier(target) else { return false }
            return run(iTermScript(target: target, body: "write text (ASCII character 27) newline false")) == "ok"
        case .terminal:
            guard focus(target) else { return false }
            usleep(50_000)
            guard targetVerifier(target) else { return false }
            return NativeTerminalCancelPolicy.result(
                focusSucceeded: true,
                keyPostSucceeded: keyPoster(53)
            )
        }
    }

    /// Send Claude Code's provider-native Shift+Tab to the verified terminal.
    /// The optional poster is an injection seam for tests; production resolves
    /// the host application and posts a real modifier/key envelope to it.
    public func cyclePermissionMode(_ target: NativeHelperTerminalTarget) -> Bool {
        guard targetVerifier(target) else { return false }
        if let permissionModePoster {
            return permissionModePoster(target) && targetVerifier(target)
        }
        guard focus(target), targetVerifier(target),
              let applicationPID = applicationPID(for: target.application),
              Self.postShiftTab(to: applicationPID),
              targetVerifier(target) else {
            return false
        }
        return true
    }

    private func withMarker(
        _ target: NativeHelperTerminalTarget,
        action: (String) -> Bool
    ) -> Bool {
        guard targetVerifier(target) else { return false }
        let marker = GhosttyMarkerLocator.makeMarker()
        let ttyPath = target.tty.hasPrefix("/dev/") ? target.tty : "/dev/\(target.tty)"
        guard write(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath) else {
            return false
        }
        usleep(100_000)
        // The marker write above was only a locator. Do not execute the
        // provider action if the process instance changed during the settle
        // window; the next write must be fail-closed as well.
        guard targetVerifier(target) else { return false }
        let result = action(marker)
        guard targetVerifier(target) else { return false }
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
        // Keep AppleScript out of the helper process in-process execution
        // path. A hung target must terminate before the caller can release a
        // serialized terminal lane; otherwise a later session could write
        // after this operation appears to have failed.
        return Self.commandOutput(
            "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: 2
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    public static func postKey(_ key: CGKeyCode) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func applicationPID(for application: NativeHelperTerminalApplication) -> pid_t? {
        let bundleIdentifier: String
        switch application {
        case .ghostty: bundleIdentifier = "com.mitchellh.ghostty"
        case .iTerm2: bundleIdentifier = "com.googlecode.iterm2"
        case .terminal: bundleIdentifier = "com.apple.Terminal"
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }?.processIdentifier
    }

    private static func postShiftTab(to pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (0x38, true, []),
            (0x30, true, .maskShift),
            (0x30, false, .maskShift),
            (0x38, false, []),
        ]
        var posted = false
        for (key, down, flags) in events {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: key,
                keyDown: down
            ) else { return false }
            event.flags = flags
            event.postToPid(pid)
            posted = true
        }
        return posted
    }

    /// Re-resolve the process instance at the action boundary. TTYs and PIDs
    /// are reusable; the token binds them to the launch observed by the
    /// provider. TTY and cwd are checked as well so a reused process target
    /// cannot accidentally receive a prompt or Escape.
    public static func liveTargetMatches(_ target: NativeHelperTerminalTarget) -> Bool {
        guard let pid = target.pid, pid > 0,
              let suppliedToken = target.processStartToken,
              !suppliedToken.isEmpty,
              let liveToken = liveProcessStartToken(pid: pid),
              suppliedToken == liveToken,
              liveTTY(pid: pid) == normalizedTTYValue(target.tty),
              liveCWD(pid: pid) == target.cwd else {
            return false
        }
        return true
    }

    /// Shared with the Electron provider token format:
    /// `v1:<pid>:<start-millis>:<sha256(pid|start-millis)>`.
    public static func processStartToken(pid: Int32) -> String? {
        liveProcessStartToken(pid: pid)
    }

    public static func processInstanceToken(pid: Int32, startTime: Date) -> String {
        TerminalProcessIdentityToken.make(pid: Int(pid), startTime: startTime)
    }

    private static func liveProcessStartToken(pid: Int32) -> String? {
        guard let startedAt = processStartedAt(pid: pid) else { return nil }
        return processInstanceToken(pid: pid, startTime: startedAt)
    }

    private static func processStartedAt(pid: Int32) -> Date? {
        guard let output = commandOutput(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "lstart="]
        ) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func liveTTY(pid: Int32) -> String? {
        guard let output = commandOutput(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "tty="]
        ) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "?", value != "??", value != "-" else { return nil }
        return normalizedTTYValue(value)
    }

    private static func liveCWD(pid: Int32) -> String? {
        guard let output = commandOutput(
            "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        ) else { return nil }
        return output.split(separator: "\n")
            .first(where: { $0.first == "n" })
            .map { String($0.dropFirst()) }
    }

    private static func normalizedTTYValue(_ value: String) -> String {
        value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
    }

    private static func commandOutput(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 1
    ) -> String? {
        let process = Process()
        let pipe = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if termination.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 0.25)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
