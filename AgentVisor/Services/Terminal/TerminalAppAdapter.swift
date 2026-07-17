import AppKit
import AgentVisorCore
import Foundation
import os.log

struct TerminalAppAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")
    private static let bundleIdentifier = "com.apple.Terminal"

    nonisolated init() {}

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        guard let ttyName = ttyName(for: session) else { return false }
        let script = TerminalAppSessionLocator.sendTextScript(
            ttyName: ttyName,
            text: text
        )
        return runAppleScript(script) == "ok"
    }

    func focusSession(_ session: SessionState) -> Bool {
        let sid4 = String(session.sessionId.prefix(4))
        guard let ttyName = ttyName(for: session) else {
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
