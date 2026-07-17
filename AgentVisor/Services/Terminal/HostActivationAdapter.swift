//
//  HostActivationAdapter.swift
//  AgentVisor
//
//  Read-only adapter for hosts that have NO public IPC for revealing
//  a specific session inside their UI — Zed (and any future ACP-style
//  host that lands in this category). focusSession just activates the
//  app and posts a toast explaining the limitation; sendText returns
//  false so the composer disables itself via the existing
//  EndedSessionBanner.readOnlyIDE branch.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

struct HostActivationAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "HostActivationAdapter")

    let bundleID: String
    let displayName: String

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        // No supported send path — Zed runs the agent over ACP (stdio
        // between Zed and a child process). agent-visor cannot inject
        // into that pipe.
        Self.logger.info("sendText: no-op for read-only host \(displayName, privacy: .public)")
        return false
    }

    func focusSession(_ session: SessionState) -> Bool {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else {
            Self.logger.info("focusSession: \(displayName, privacy: .public) not running")
            return false
        }
        app.activate()
        Self.logger.error("focusSession: activated \(displayName, privacy: .public) sid=\(session.sessionId.prefix(4), privacy: .public)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cvShowToast,
                object: nil,
                userInfo: [
                    "text": "Activated \(displayName). \(displayName) doesn't expose a way to reveal a specific agent thread — find it in \(displayName)'s sidebar."
                ]
            )
        }
        return true
    }
}
