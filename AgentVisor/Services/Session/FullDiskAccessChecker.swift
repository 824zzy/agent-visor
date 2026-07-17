//
//  FullDiskAccessChecker.swift
//  AgentVisor
//
//  Detects the macOS 15 Sequoia silent-deny on reads of claude-code's
//  session JSONLs (com.apple.provenance xattr written by another app) and
//  surfaces a one-time-per-launch modal pointing the user at System
//  Settings → Privacy & Security → Full Disk Access.
//
//  See README "Why does it need Full Disk Access on Sequoia?" for context.
//

import Foundation
import AppKit
import AgentVisorCore
import os.log

@MainActor
enum FullDiskAccessChecker {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "FullDiskAccess")
    private static var hasPromptedThisLaunch = false

    /// Call from any JSONL-open failure site under `~/.claude/projects/`.
    /// No-op unless the error is `NSCocoaErrorDomain` / `NSFileReadNoPermissionError`
    /// (code 257) — the exact signature of the Sequoia provenance silent-deny.
    /// Rate-limited to one prompt per app launch so we don't spam.
    static func reportOpenFailure(error: Error, path: String) {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain,
              ns.code == NSFileReadNoPermissionError else { return }
        guard path.contains("/.claude/projects/") else { return }
        guard !hasPromptedThisLaunch else { return }
        hasPromptedThisLaunch = true

        logger.error("FDA denied on \(path, privacy: .public) — prompting user")
        showAlert()
    }

    private static func showAlert() {
        let alert = NSAlert()
        alert.messageText = "\(AppBranding.appName) needs Full Disk Access"
        alert.informativeText = """
        On macOS 15 Sequoia and later, \(AppBranding.appName) needs Full Disk Access to read each agent's session transcripts (~/.claude/projects, ~/.codex/sessions, ~/.cursor/projects). Without it the chat history stays empty even though sessions are running.

        Open System Settings → Privacy & Security → Full Disk Access, add \(AppBranding.appName), then relaunch.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openFullDiskAccessSettings()
        }
    }

    private static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
