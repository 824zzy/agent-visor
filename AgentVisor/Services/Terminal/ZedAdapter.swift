//
//  ZedAdapter.swift
//  AgentVisor
//
//  Navigation for sessions Zed hosts over ACP.
//
//  What Zed gives us and what it doesn't (verified against Zed 1.14 and
//  `zed-industries/zed@main`):
//    * no thread deeplink — `zed://agent` maps to `AgentPanel` and always
//      creates a NEW thread in an arbitrary active workspace, so it must
//      never be used to "return" to a session;
//    * no agent flags on the `zed` CLI;
//    * no accessible UI tree for sidebar rows;
//    * but a documented keyboard path that activates a thread by title,
//      including threads whose workspace is currently closed.
//
//  So focusSession does three escalating things, each verified:
//    1. activate the running Zed (any release channel);
//    2. open or raise the thread's recorded worktree, so the target row is
//       present in that window's workspace sidebar;
//    3. reveal the exact thread by driving Zed's sidebar filter, then
//       confirm the result against Zed's serialized Agent Panel state.
//
//  Every failure degrades to an honest toast that names the thread the
//  user is looking for. `sendText` stays false: Zed owns the composer,
//  and Chat renders read-only for these sessions.
//

import AgentVisorCore
import AppKit
import Foundation
import os.log

struct ZedAdapter: TerminalAdapter {
    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "ZedAdapter"
    )

    /// Channel recorded at construction. Navigation re-resolves the
    /// running channel at click time, so this is only the fallback.
    let channel: ZedChannel

    var bundleID: String { channel.bundleID }
    var displayName: String { channel.displayName }

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        // Zed drives the agent over its own ACP stdio pipe; there is no
        // public seam to inject a prompt. Chat shows the read-only banner.
        Self.logger.info("sendText: no-op for read-only host \(displayName, privacy: .public)")
        return false
    }

    func focusSession(_ session: SessionState) -> Bool {
        let thread = ZedThreadStore.thread(sessionID: session.sessionId)
        let threadTitle = thread?.displayTitle
        let resolved = ZedThreadStore.runningApp()
            ?? NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first
                .map { ($0, channel) }

        guard let (app, runningChannel) = resolved else {
            Self.logger.info("focusSession: no Zed channel running")
            return false
        }
        let appName = runningChannel.displayName

        let worktreePath = thread?.primaryWorktreePath ?? session.cwd
        // Zed's workspace sidebar only contains rows for project groups in
        // that window. Delivering the path first is therefore required for
        // a thread whose project is currently closed; it also raises the
        // existing window when the worktree is already open.
        if !openViaLaunchServices(
            bundleID: app.bundleIdentifier ?? runningChannel.bundleID,
            path: worktreePath
        ) {
            Self.logger.error("focusSession: failed to open worktree path=\(worktreePath, privacy: .public)")
        }

        guard let activated = TerminalHostActivator.activateAndWait(
            bundleIdentifier: runningChannel.bundleID
        ) else {
            Self.logger.error("focusSession: \(appName, privacy: .public) did not come frontmost")
            Self.postToast(Self.fallbackToast(appName: appName, threadTitle: threadTitle))
            return false
        }

        guard AppSettings.zedThreadRevealEnabled else {
            Self.logger.notice("focusSession: reveal disabled by setting")
            Self.postToast(Self.fallbackToast(appName: appName, threadTitle: threadTitle))
            return true
        }

        guard let thread, let threadTitle else {
            // No Zed title yet (fresh thread) — there is nothing to type
            // that would identify the row, so stop at activation.
            Self.logger.notice("focusSession: no Zed thread title for sid=\(session.sessionId.prefix(8), privacy: .public)")
            Self.postToast(Self.fallbackToast(appName: appName, threadTitle: nil))
            return true
        }

        guard ZedThreadStore.hasUniqueLiveRevealQuery(thread) else {
            Self.logger.notice("focusSession: duplicate or unusable Zed title for sid=\(session.sessionId.prefix(8), privacy: .public)")
            Self.postToast(
                "Activated \(appName). More than one Zed thread is named “\(threadTitle)” — select the right one in the thread sidebar."
            )
            return true
        }

        let outcome = reveal(
            thread: thread,
            title: threadTitle,
            worktreePath: worktreePath,
            app: activated
        )
        switch outcome {
        case .revealed:
            Self.logger.notice("focusSession: revealed thread=\(thread.threadID.prefix(8), privacy: .public)")
            _ = ZedKeystrokeSender.run(
                plan: ZedThreadRevealPlanner.cleanupPlan(),
                app: activated
            )
        case .openedDifferentThread(let otherID):
            Self.logger.error("focusSession: reveal opened other thread=\(otherID.prefix(8), privacy: .public)")
            Self.postToast(
                "\(appName) opened a different thread. Filter for “\(threadTitle)” in \(appName)'s sidebar."
            )
        case .unverified:
            Self.logger.error("focusSession: reveal unverified for thread=\(thread.threadID.prefix(8), privacy: .public)")
            Self.postToast(Self.fallbackToast(appName: appName, threadTitle: threadTitle))
        }
        return true
    }

    // MARK: - Reveal

    private func reveal(
        thread: ZedThreadRecord,
        title: String,
        worktreePath: String,
        app: NSRunningApplication
    ) -> ZedThreadRevealOutcome {
        let plan = ZedThreadRevealPlanner.plan(title: title)

        // A newly opened worktree may need one render pass before its
        // threads enter the sidebar. Retry the entire idempotent sequence
        // once; the plan replaces any previous filter before typing.
        var lastOutcome = ZedThreadRevealOutcome.unverified
        for attempt in 0..<2 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.65)
            }
            guard ZedKeystrokeSender.run(plan: plan, app: app) else {
                return .unverified
            }

            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
                let after = ZedThreadStore.activePanelSelection(worktreePath: worktreePath)
                lastOutcome = ZedThreadRevealVerifier.outcome(
                    targetThreadID: thread.threadID,
                    targetSessionID: thread.sessionID,
                    selection: after
                )
                if lastOutcome == .revealed { return lastOutcome }
            }
        }
        return lastOutcome
    }

    /// `open -b <bundle id> <path>`: Zed's open-document handler focuses
    /// the existing workspace or opens it when the target project is closed.
    private func openViaLaunchServices(bundleID: String, path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-b", bundleID, path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Copy

    private static func fallbackToast(appName: String, threadTitle: String?) -> String {
        if let threadTitle {
            return "Activated \(appName). Find “\(threadTitle)” in \(appName)'s thread sidebar."
        }
        return "Activated \(appName). \(appName) hasn't named this thread yet — find it in \(appName)'s thread sidebar."
    }

    private static func postToast(_ text: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: ["text": text]
            )
        }
    }
}
