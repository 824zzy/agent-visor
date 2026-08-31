import AppKit
import AgentVisorCore
import Foundation
import os.log

struct GhosttyAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")
    private static let bundleIdentifier = "com.mitchellh.ghostty"

    nonisolated init() {}

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        sendTextOutcome(
            text,
            toSession: session,
            operationID: ProcessExecutor.currentOperationID
        ).isDelivered
    }

    func sendTextOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalAttachmentDeliveryOutcome {
        GhosttyScripting.sendInputOutcome(
            text,
            toSession: session,
            operationID: operationID
        )
    }

    func focusSession(_ session: SessionState) -> Bool {
        let sid4 = String(session.sessionId.prefix(4))
        guard TerminalProcessIdentityResolver.isVerified(session),
              let tty = session.tty, !tty.isEmpty else {
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
            originalCwd: observedCwd,
            sid4: sid4
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

    private func focusByTTYMarker(
        ttyPath: String,
        originalCwd: String,
        sid4: String
    ) -> Bool {
        let marker = GhosttyMarkerLocator.makeMarker()
        let writeStarted = Date()
        let wroteMarker = write(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath)
        let writeMs = Int(Date().timeIntervalSince(writeStarted) * 1_000)
        guard wroteMarker else {
            Self.logger.notice("ghostty marker sid=\(sid4, privacy: .public) writeMs=\(writeMs) result=writeFailed")
            return false
        }
        usleep(100_000)

        let scriptStarted = Date()
        let result = runAppleScript(GhosttyMarkerLocator.focusScript(marker: marker))
        let scriptMs = Int(Date().timeIntervalSince(scriptStarted) * 1_000)
        let restoreStarted = Date()
        let restored = write(GhosttyMarkerLocator.osc7Sequence(cwd: originalCwd), to: ttyPath)
        let restoreMs = Int(Date().timeIntervalSince(restoreStarted) * 1_000)
        Self.logger.notice("ghostty marker sid=\(sid4, privacy: .public) writeMs=\(writeMs) scriptMs=\(scriptMs) restoreMs=\(restoreMs) located=\(result == "ok") restored=\(restored)")
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
        switch ProcessExecutor.shared.runSyncWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: SubprocessDeadlinePolicy.appCommand
        ) {
        case .success(let result):
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            return ""
        }
    }
}
