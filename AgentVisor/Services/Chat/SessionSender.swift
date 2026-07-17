//
//  SessionSender.swift
//  AgentVisor
//
//  Send-text-to-session helper used by the window-mode composer.
//  Routes the message to the right adapter for the session's origin/host:
//      - .visorSpawned        → SpawnedSessionManager (writes to pty)
//      - tmux session         → ToolApprovalHandler.sendMessage
//      - registry adapter     → adapter.sendText
//      - Ghostty fallback     → GhosttyScripting.sendInput
//      - no TTY               → fail
//
//  Optionally registers a global ESC catch-net for the duration of the
//  AppleScript focus-theft window so ESC reaches the caller's cancel
//  handler.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

@MainActor
enum SessionSender {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SessionSender")

    /// Send `text` to the session, plus optional images. Codex app-server
    /// receives images as `localImage` input items; terminal-backed agents
    /// receive images through the TTY paste helper.
    static func send(
        text: String,
        attachments: [ImageAttachment] = [],
        to session: SessionState,
        keepFocusOnHost: Bool = true,
        onEscDuringSend: @MainActor @escaping () -> Void = {}
    ) async {
        if session.agentID == .codex,
           CodexSendRoutePolicy.route(for: session.codexControlCapability) != .unavailable {
            await sendCodexTurn(text: text, attachments: attachments, to: session)
            return
        }

        // Image-paste path is TTY-only. Cursor's CC extension sessions
        // have no TTY; we skip image attachments for them.
        if session.tty != nil {
            for attachment in attachments {
                _ = await ImagePasteSender.sendPaste(path: attachment.url.path, session: session)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        if !text.isEmpty {
            await sendTextOnly(text, to: session, keepFocusOnHost: keepFocusOnHost, onEscDuringSend: onEscDuringSend)
        } else if !attachments.isEmpty, session.tty != nil {
            // Image-only — pastes left placeholder text in the TUI; press Enter.
            _ = await ImagePasteSender.sendEnter(session: session)
        }
    }

    private static func sendCodexTurn(
        text: String,
        attachments: [ImageAttachment],
        to session: SessionState
    ) async {
        let threadId = session.sessionId
        let imagePaths = attachments.map { $0.url.path }
        guard !text.isEmpty || !imagePaths.isEmpty else { return }
        do {
            switch CodexSendRoutePolicy.route(for: session.codexControlCapability) {
            case .managedAppServer:
                try await CodexAppServerClient.shared.sendTurn(
                    threadId: threadId,
                    text: text,
                    localImagePaths: imagePaths,
                    approvalPolicy: session.conversationInfo.lastCodexApprovalPolicy,
                    sandboxPolicyType: session.conversationInfo.lastCodexSandboxPolicyType
                )
            case .sharedAppServer:
                try await CodexConnectedRuntimeCoordinator.shared.sendTurn(
                    threadId: threadId,
                    text: text,
                    localImagePaths: imagePaths
                )
            case .unavailable:
                return
            }
            logger.info(
                "codex app-server turn ok sid=\(threadId.prefix(8), privacy: .public) len=\(text.count, privacy: .public) images=\(imagePaths.count, privacy: .public)"
            )
        } catch {
            logger.error(
                "codex app-server turn FAILED sid=\(threadId.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func sendTextOnly(
        _ text: String,
        to session: SessionState,
        keepFocusOnHost: Bool,
        onEscDuringSend: @MainActor @escaping () -> Void
    ) async {
        // visor-spawned: silent pty write.
        if session.origin == .visorSpawned {
            do {
                try await SpawnedSessionManager.shared.writeMessage(text, to: session.sessionId)
            } catch {
                logger.error("visor-spawn writeMessage failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        // tmux: send-keys via the resolved target.
        if let tty = session.tty,
           session.isInTmux,
           let target = await findTmuxTarget(tty: tty) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
            return
        }

        // ESC catch-net only registered for the notch caller.
        var escapeMonitor: Any?
        if keepFocusOnHost {
            if !AXIsProcessTrusted() {
                logger.warning("ESC monitor: AX not trusted, global keyDown monitor will silently no-op")
            }
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return }
                DispatchQueue.main.async {
                    Task { @MainActor in onEscDuringSend() }
                }
            }
        }
        defer {
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        // Background-dispatch the AppleScript path (1-2s), surface the
        // result via os_log.
        let sessionCopy = session
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok: Bool
                let route: String
                if let adapter = TerminalAdapterRegistry.adapter(for: sessionCopy) {
                    ok = adapter.sendText(text, toSession: sessionCopy)
                    route = "registry"
                } else if sessionCopy.tty != nil {
                    ok = GhosttyScripting.sendInput(text, toSession: sessionCopy)
                    route = "ghostty"
                } else {
                    ok = false
                    route = "noTTY"
                }
                if ok {
                    Self.logger.info("submit ok route=\(route, privacy: .public) sid=\(sessionCopy.sessionId.prefix(8), privacy: .public) len=\(text.count, privacy: .public)")
                } else {
                    Self.logger.error("submit FAILED route=\(route, privacy: .public) sid=\(sessionCopy.sessionId.prefix(8), privacy: .public) len=\(text.count, privacy: .public) tty=\(sessionCopy.tty ?? "nil", privacy: .public)")
                }
                continuation.resume()
            }
        }

        // `keepFocusOnHost` was the notch-panel-era hook for re-keying
        // the panel after the AppleScript focus-theft window. The notch
        // panel is gone; window mode never sets it, so this path is
        // intentionally a no-op. Kept the parameter as an inert flag
        // so the existing call sites don't need updating; a follow-up
        // pass can drop both it and the dead helpers below.
        _ = keepFocusOnHost
    }

    private static func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }
        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }
                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

}
