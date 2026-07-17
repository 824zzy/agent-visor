//
//  TerminalAdapterRegistry.swift
//  AgentVisor
//
//  Picks the right TerminalAdapter for a session based on which terminal
//  app is hosting the Claude Code process. Resolution walks the parent
//  process chain via TerminalHostDetector. Returns nil for sessions
//  hosted in non-terminal apps or unsupported terminal hosts.
//

import AppKit
import AgentVisorCore
import Foundation

enum TerminalAdapterRegistry {
    nonisolated static func adapter(for session: SessionState) -> TerminalAdapter? {
        let host: TerminalHost
        if let recordedHost = session.terminalHost, recordedHost != .unknown {
            host = recordedHost
        } else if let pid = session.pid {
            host = TerminalHostDetector.detect(
                pid: pid_t(pid),
                reader: LiveProcessInfoReader.shared
            )
        } else {
            return nil
        }
        switch host {
        case .iterm2:
            return ITermAdapter()
        case .vscode:
            // Same adapter for VS Code stable and Insiders. We use the
            // stable bundle ID by default for activation; if the actual
            // running app is Insiders, NSRunningApplication's lookup will
            // return nil for the stable ID and the adapter falls through.
            // Re-route based on which channel is actually running.
            if NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first != nil {
                return EditorAdapter(bundleID: "com.microsoft.VSCode", displayName: "VS Code")
            }
            return EditorAdapter(
                bundleID: "com.microsoft.VSCodeInsiders",
                displayName: "VS Code Insiders"
            )
        case .cursor:
            return EditorAdapter(
                bundleID: "com.todesktop.230313mzl4w4u92",
                displayName: "Cursor"
            )
        case .zed:
            // Read-only: Zed exposes no public IPC for thread reveal,
            // and ACP runs over stdio inside the host. We can only
            // raise the app and tell the user where to find the thread.
            return HostActivationAdapter(
                bundleID: "dev.zed.Zed",
                displayName: "Zed"
            )
        case .ghostty:
            return GhosttyAdapter()
        case .terminalApp:
            return TerminalAppAdapter()
        case .claudeDesktop, .codexApp, .unknown:
            return nil
        }
    }
}
