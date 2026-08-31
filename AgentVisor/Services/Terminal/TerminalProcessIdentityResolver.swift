import AgentVisorCore
import Foundation

/// Reads the provider process identity again at the last safe point before a
/// direct AppKit/AppleScript action. A cached PID or TTY is not sufficient:
/// both can be reused by a different terminal process.
enum TerminalProcessIdentityResolver {
    /// Run the blocking process/terminal probe away from the MainActor. UI
    /// capability checks use this asynchronous seam; irreversible adapter
    /// actions still call `isVerified` immediately before writing.
    nonisolated static func isVerifiedAsync(_ session: SessionState) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            isVerified(session)
        }.value
    }

    nonisolated static func isVerified(_ session: SessionState) -> Bool {
        guard let pid = session.pid,
              let expectedToken = session.processStartToken,
              let expectedTTY = session.tty,
              let expectedHost = session.terminalHost,
              expectedHost != .unknown,
              let liveToken = startToken(pid: pid),
              let liveTTY = liveTTY(pid: pid) else {
            return false
        }
        let expected = TerminalProcessIdentity(
            pid: pid,
            processStartToken: expectedToken,
            tty: expectedTTY
        )
        let live = TerminalProcessIdentity(
            pid: pid,
            processStartToken: liveToken,
            tty: liveTTY
        )
        guard TerminalProcessIdentityPolicy.matches(expected: expected, live: live) else {
            return false
        }
        return TerminalHostDetector.detect(
            pid: pid_t(pid),
            reader: LiveProcessInfoReader.shared
        ) == expectedHost
    }

    nonisolated static func startToken(pid: Int) -> String? {
        guard pid > 0,
              let output = processOutput(
                  "/bin/ps",
                  arguments: ["-p", String(pid), "-o", "lstart="]
              ) else { return nil }
        guard let start = TerminalProcessProbeParser.startDate(from: output) else {
            return nil
        }
        return TerminalProcessIdentityToken.make(pid: pid, startTime: start)
    }

    nonisolated private static func liveTTY(pid: Int) -> String? {
        guard let output = processOutput(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "tty="]
        ) else { return nil }
        return TerminalProcessProbeParser.tty(from: output)
    }

    nonisolated private static func processOutput(
        _ executable: String,
        arguments: [String]
    ) -> String? {
        switch ProcessExecutor.shared.runSyncWithResult(
            executable,
            arguments: arguments,
            timeout: SubprocessDeadlinePolicy.localRead
        ) {
        case .success(let result) where result.isSuccess && !result.output.isEmpty:
            return result.output
        case .success, .failure:
            return nil
        }
    }
}
