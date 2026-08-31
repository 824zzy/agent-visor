import AppKit
import AgentVisorCore
import Foundation
import os.log

struct TerminalAppAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")
    private static let bundleIdentifier = "com.apple.Terminal"

    nonisolated init() {}

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              TerminalTextPolicy.canSend(text) else { return false }
        guard let ttyName = ttyName(for: session) else { return false }
        let script = TerminalAppSessionLocator.sendTextScript(
            ttyName: ttyName,
            text: text
        )
        return runAppleScript(
            script,
            operationID: ProcessExecutor.currentOperationID
        ) == "ok"
    }

    /// Terminal.app has no per-tab AppleScript key verb. Use its exact TTY
    /// selection route followed by System Events' Escape key code; never
    /// fall through to Ghostty for a Terminal.app session. The caller's
    /// serialized cancel transaction supplies the bounded operation lease.
    func sendEscape(
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let script = TerminalAppSessionLocator.escapeScript(ttyName: ttyName)
        return runAppleScript(script, operationID: operationID) == "ok"
    }

    func sendBackspaces(
        count: Int,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard count > 0,
              TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let script = TerminalAppSessionLocator.backspaceScript(
            ttyName: ttyName,
            count: count
        )
        return runAppleScript(script, operationID: operationID) == "ok"
    }

    func focusSession(_ session: SessionState) -> Bool {
        let sid4 = String(session.sessionId.prefix(4))
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else {
            Self.logger.notice("terminal focus sid=\(sid4, privacy: .public) result=fail reason=noTTY")
            return false
        }
        guard let app = TerminalHostActivator.activateAndWait(
            bundleIdentifier: Self.bundleIdentifier
        ) else {
            Self.logger.notice("terminal focus sid=\(sid4, privacy: .public) result=fail reason=activation")
            return false
        }

        let script = TerminalAppSessionLocator.focusScript(ttyName: ttyName)
        let selectedTargetMatches = runAppleScript(script) == "ok"
        let hostIsFrontmost = TerminalHostActivator.isFrontmost(app)
        let success = TerminalFocusVerificationPolicy.isSuccessful(
            selectedTargetMatches: selectedTargetMatches,
            hostIsFrontmost: hostIsFrontmost
        )
        Self.logger.notice("terminal focus sid=\(sid4, privacy: .public) tty=\(ttyName, privacy: .public) selected=\(selectedTargetMatches) frontmost=\(hostIsFrontmost) result=\(success ? "ok" : "fail", privacy: .public)")
        return success
    }

    private func ttyName(for session: SessionState) -> String? {
        guard let tty = session.tty, !tty.isEmpty else { return nil }
        return ITermSessionLocator.normalizeTTY(tty)
    }

    private func runAppleScript(
        _ source: String,
        operationID: String? = nil
    ) -> String {
        let result: Result<ProcessResult, ProcessExecutorError>
        if let operationID {
            result = ProcessExecutor.shared.runSyncWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: SubprocessDeadlinePolicy.appCommand,
                operationID: operationID
            )
        } else {
            result = ProcessExecutor.shared.runSyncWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: SubprocessDeadlinePolicy.appCommand
            )
        }
        switch result {
        case .success(let result):
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            return ""
        }
    }
}
