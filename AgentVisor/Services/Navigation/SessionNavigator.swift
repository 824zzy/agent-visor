import AppKit
import AgentVisorCore
import os.log

struct SessionNavigator {
    private static let pillNavLog = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "PillNav"
    )
    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    static func navigateToSession(_ session: SessionState) {
        DispatchQueue.global(qos: .userInitiated).async {
            navigateOnBackground(session)
        }
    }

    private static func navigateOnBackground(_ session: SessionState) {
        let sid8 = String(session.sessionId.prefix(8))
        let host = session.terminalHost.map(String.init(describing:)) ?? "nil"
        pillNavLog.notice("nav enter sid=\(sid8, privacy: .public) project=\(session.bestProjectName, privacy: .public) pid=\(session.pid ?? -1) tty=\(session.tty ?? "none", privacy: .public) cwd=\(session.cwd, privacy: .public) lastCwd=\(session.conversationInfo.lastCwd ?? "nil", privacy: .public) host=\(host, privacy: .public)")
        pillNavLog.notice("nav enter stableId=\(session.stableId, privacy: .public) sessionName=\(session.sessionName ?? "nil", privacy: .public)")

        if let adapter = TerminalAdapterRegistry.adapter(for: session) {
            let adapterName = String(describing: type(of: adapter))
            let focused = adapter.focusSession(session)
            pillNavLog.notice("nav adapter=\(adapterName, privacy: .public) sid=\(sid8, privacy: .public) result=\(focused ? "ok" : "fail", privacy: .public)")
            if !focused {
                pillNavLog.notice("nav fallback=none sid=\(sid8, privacy: .public) reason=exactFocusFailed")
            }
            return
        }

        pillNavLog.notice("nav adapter=none sid=\(sid8, privacy: .public)")
        if session.tty != nil {
            pillNavLog.notice("nav fallback=none sid=\(sid8, privacy: .public) reason=unsupportedTerminalHost")
            return
        }

        if session.agentID == .codex {
            pillNavLog.notice("nav codex open-thread sid=\(sid8, privacy: .public)")
            Task { @MainActor in
                CodexAgentProvider.openThreadInApp(session.sessionId)
            }
            return
        }

        if focusClaudeDesktop() {
            pillNavLog.notice("nav fallback=ClaudeDesktop sid=\(sid8, privacy: .public) reason=noTTY result=ok")
        } else {
            pillNavLog.notice("nav fallback=none sid=\(sid8, privacy: .public) reason=noTTY+noClaudeDesktop")
        }
    }

    private static func focusClaudeDesktop() -> Bool {
        TerminalHostActivator.activateAndWait(
            bundleIdentifier: claudeDesktopBundleID
        ) != nil
    }
}
