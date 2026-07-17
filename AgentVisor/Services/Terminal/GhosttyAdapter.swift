import AppKit
import AgentVisorCore
import Foundation
import os.log

struct GhosttyAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")
    private static let bundleIdentifier = "com.mitchellh.ghostty"

    nonisolated init() {}

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        GhosttyScripting.sendInput(text, toSession: session)
    }

    func focusSession(_ session: SessionState) -> Bool {
        let sid4 = String(session.sessionId.prefix(4))
        guard let tty = session.tty, !tty.isEmpty else {
            Self.logger.notice("ghostty focus sid=\(sid4, privacy: .public) result=fail reason=noTTY")
            return false
        }
        guard let app = TerminalHostActivator.activateAndWait(
            bundleIdentifier: Self.bundleIdentifier
        ) else {
            Self.logger.notice("ghostty focus sid=\(sid4, privacy: .public) result=fail reason=activation")
            return false
        }

        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let observedCwd = session.conversationInfo.lastCwd ?? session.cwd
        var selectedTargetMatches = focusByTTYMarker(
            ttyPath: ttyPath,
            originalCwd: observedCwd
        )
        if !selectedTargetMatches {
            selectedTargetMatches = focusUniqueCwd(observedCwd)
        }
        if !selectedTargetMatches, observedCwd != session.cwd {
            selectedTargetMatches = focusUniqueCwd(session.cwd)
        }
        let hostIsFrontmost = TerminalHostActivator.isFrontmost(app)
        let success = TerminalFocusVerificationPolicy.isSuccessful(
            selectedTargetMatches: selectedTargetMatches,
            hostIsFrontmost: hostIsFrontmost
        )
        Self.logger.notice("ghostty focus sid=\(sid4, privacy: .public) selected=\(selectedTargetMatches) frontmost=\(hostIsFrontmost) result=\(success ? "ok" : "fail", privacy: .public)")
        return success
    }

    private func focusByTTYMarker(ttyPath: String, originalCwd: String) -> Bool {
        let marker = GhosttyMarkerLocator.makeMarker()
        guard write(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath) else {
            return false
        }
        usleep(100_000)

        let result = runAppleScript(GhosttyMarkerLocator.focusScript(marker: marker))
        _ = write(GhosttyMarkerLocator.osc7Sequence(cwd: originalCwd), to: ttyPath)
        return result == "ok"
    }

    private func focusUniqueCwd(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        let escapedCwd = AppleScriptEscaper.escape(cwd)
        let script = """
        tell application "Ghostty"
            set targetId to missing value
            set matchCount to 0
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(escapedCwd)" then
                            set matchCount to matchCount + 1
                            set targetId to id of t
                        end if
                    end try
                end repeat
            end repeat
            if matchCount is not 1 or targetId is missing value then return "not-unique"
            focus (terminal id targetId)
            delay 0.05
            try
                set focusedId to id of focused terminal of selected tab of front window
                if focusedId is targetId then return "ok"
            end try
            return "focus-mismatch"
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private func write(_ text: String, to ttyPath: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = text.data(using: .utf8) else {
            return false
        }
        handle.write(data)
        handle.closeFile()
        return true
    }

    private func runAppleScript(_ source: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}
