//
//  SessionSender.swift
//  AgentVisor
//
//  Send-text-to-session helper used by the window-mode composer.
//  Routes the message to the right adapter for the session's origin/host:
//      - .visorSpawned        → SpawnedSessionManager (writes to pty)
//      - tmux session         → ToolApprovalHandler.sendMessage
//      - registry adapter     → adapter.sendTextOutcome
//      - Ghostty fallback     → GhosttyScripting.sendInputOutcome
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

    /// Send `text` plus optional images through provider-specific semantics.
    /// Codex receives local-image input items, Claude's terminal TUI receives
    /// attachment-aware path pastes, and Pi receives one ordered path prompt.
    static func send(
        text: String,
        attachments: [ImageAttachment] = [],
        to session: SessionState,
        keepFocusOnHost: Bool = true,
        onEscDuringSend: @MainActor @escaping () -> Void = {}
    ) async -> TerminalAttachmentDeliveryOutcome {
        // Every terminal path (including attachment paste) shares one bounded
        // transaction with WindowComposer's Escape and prompt-clear operation.
        // The inner attachment/text steps deliberately do not reacquire the
        // lane; nested acquisition would deadlock a compound send.
        let operationID = "chat-send-\(UUID().uuidString)"
        do {
            return try await TerminalTransportSerializer.shared.withLane(
                sessionID: session.sessionId,
                ownerID: operationID,
                operation: {
                    await sendUnlocked(
                        text: text,
                        attachments: attachments,
                        to: session,
                        keepFocusOnHost: keepFocusOnHost,
                        onEscDuringSend: onEscDuringSend,
                        operationID: operationID
                    )
                },
                terminate: {
                    // ProcessExecutor terminates and waits for every bounded
                    // child associated with this transport transaction before
                    // the lane can advance. This is the production hook; the
                    // serializer's compatibility shim is never used here.
                    await ProcessExecutor.shared.terminateActiveProcesses(
                        operationID: operationID
                    )
                }
            )
        } catch TerminalTransportSerializerError.operationTimedOut {
            // The executor terminates the bounded AppleScript child before
            // this result returns. Since a compound transport may have
            // emitted an earlier step, keep the outcome conservative.
            return .uncertainAfterPartialWrite(
                reason: "Terminal delivery timed out after the transport started.",
                completedSteps: []
            )
        } catch TerminalTransportSerializerError.acquisitionTimedOut {
            return .failedBeforeWrite(reason: "The terminal was busy; nothing was sent.")
        } catch TerminalTransportSerializerError.queueFull {
            return .failedBeforeWrite(reason: "Too many terminal actions are queued; nothing was sent.")
        } catch is CancellationError {
            return .failedBeforeWrite(reason: "The terminal send was cancelled before completion.")
        } catch {
            return .failedBeforeWrite(reason: "The terminal rejected the message before confirmation.")
        }
    }

    private static func sendUnlocked(
        text: String,
        attachments: [ImageAttachment],
        to session: SessionState,
        keepFocusOnHost: Bool,
        onEscDuringSend: @MainActor @escaping () -> Void,
        operationID: String
    ) async -> TerminalAttachmentDeliveryOutcome {
        switch session.imageSubmissionRoute {
        case .appServerLocalImage:
            guard session.agentID == .codex,
                  CodexSendRoutePolicy.route(
                    for: session.codexControlCapability
                  ) != .unavailable else {
                return .failedBeforeWrite(reason: "Codex image delivery is unavailable.")
            }
            return await sendCodexTurn(text: text, attachments: attachments, to: session)

        case .terminalPathPrompt:
            guard let prompt = PiImagePromptComposer.compose(
                text: text,
                imagePaths: attachments.map { $0.url.path }
            ), TerminalTextPolicy.canSend(prompt) else {
                logger.error("Pi terminal prompt rejected by UTF-8 byte limit")
                return .failedBeforeWrite(reason: "The Pi prompt exceeds the terminal size limit.")
            }
            let outcome = await sendTextOnly(
                prompt,
                to: session,
                keepFocusOnHost: keepFocusOnHost,
                onEscDuringSend: onEscDuringSend,
                operationID: operationID
            )
            if !outcome.isDelivered, !attachments.isEmpty {
                postImageDeliveryFailure(for: session)
            }
            return outcome

        case .terminalAttachment:
            guard session.tty != nil else {
                return .failedBeforeWrite(reason: "No verified terminal is connected.")
            }
            guard ImageAttachmentAdmissionPolicy.validate(
                attachments.map(Self.admissionMetadata(for:))
            ).isAccepted else {
                return .failedBeforeWrite(reason: "One or more image attachments are no longer valid.")
            }
            guard attachments.allSatisfy({ TerminalTextPolicy.canSend($0.url.path) }),
                  text.isEmpty || TerminalTextPolicy.canSend(text) else {
                return .failedBeforeWrite(reason: "The terminal message exceeds the UTF-8 size limit.")
            }

            var steps: [TerminalAttachmentDeliveryStep] = []
            for attachment in attachments {
                guard !Task.isCancelled else {
                    return .failedBeforeWrite(reason: "The terminal send was cancelled before the next attachment.")
                }
                let imageDelivered = await ImagePasteSender.sendPaste(
                    path: attachment.url.path,
                    session: session,
                    operationID: operationID
                )
                if imageDelivered {
                    steps.append(.succeeded(step: "attachment:\(attachment.id.uuidString)"))
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        // A serializer timeout/cancel may arrive during the
                        // settle window. Do not continue into the next
                        // irreversible attachment/text write after the lane
                        // has requested termination.
                        let completedSteps = steps.compactMap { step -> String? in
                            if case .succeeded(let name) = step { return name }
                            return nil
                        }
                        return .uncertainAfterPartialWrite(
                            reason: "Terminal delivery was cancelled after an attachment write.",
                            completedSteps: completedSteps
                        )
                    }
                } else {
                    // With a Bool adapter result the first failure is the
                    // only case that can still be treated as no-write. Once
                    // any prior step succeeded, policy returns uncertain and
                    // the caller must not offer an ordinary Retry.
                    steps.append(.failedBeforeWrite(
                        step: "attachment:\(attachment.id.uuidString)",
                        reason: "Image attachment delivery failed."
                    ))
                    return TerminalAttachmentDeliveryPolicy.outcome(for: steps)
                }
            }

            if !text.isEmpty {
                guard !Task.isCancelled else {
                    return .failedBeforeWrite(reason: "The terminal send was cancelled before text submission.")
                }
                let textOutcome = await sendTextOnly(
                    text,
                    to: session,
                    keepFocusOnHost: keepFocusOnHost,
                    onEscDuringSend: onEscDuringSend,
                    operationID: operationID
                )
                switch textOutcome {
                case .delivered:
                    steps.append(.succeeded(step: "text"))
                case .failedBeforeWrite(let reason):
                    steps.append(.failedBeforeWrite(step: "text", reason: reason))
                case .uncertainAfterPartialWrite(let reason, _):
                    steps.append(.failedAfterWrite(step: "text", reason: reason))
                }
                return TerminalAttachmentDeliveryPolicy.outcome(for: steps)
            } else if !attachments.isEmpty, session.tty != nil {
                // Image-only — the attachment-aware TUI has already consumed
                // each path; submit the remaining placeholder input.
                guard !Task.isCancelled else {
                    return .failedBeforeWrite(reason: "The terminal send was cancelled before submission.")
                }
                let enterDelivered = await ImagePasteSender.sendEnter(
                    session: session,
                    operationID: operationID
                )
                if enterDelivered {
                    steps.append(.succeeded(step: "enter"))
                } else {
                    steps.append(.failedAfterWrite(
                        step: "enter",
                        reason: "Image submission could not be confirmed."
                    ))
                }
            }
            return TerminalAttachmentDeliveryPolicy.outcome(for: steps)

        case .unavailable:
            guard !text.isEmpty else {
                return .failedBeforeWrite(reason: "This session cannot receive messages.")
            }
            return await sendTextOnly(
                text,
                to: session,
                keepFocusOnHost: keepFocusOnHost,
                onEscDuringSend: onEscDuringSend,
                operationID: operationID
            )
        }
    }

    private static func sendCodexTurn(
        text: String,
        attachments: [ImageAttachment],
        to session: SessionState
    ) async -> TerminalAttachmentDeliveryOutcome {
        let threadId = session.sessionId
        let imagePaths = attachments.map { $0.url.path }
        guard !text.isEmpty || !imagePaths.isEmpty else {
            return .failedBeforeWrite(reason: "The message is empty.")
        }
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
                return .failedBeforeWrite(reason: "Codex image delivery is unavailable.")
            }
            logger.info(
                "codex app-server turn ok sid=\(threadId.prefix(8), privacy: .public) len=\(text.count, privacy: .public) images=\(imagePaths.count, privacy: .public)"
            )
            return .delivered
        } catch {
            logger.error(
                "codex app-server turn FAILED sid=\(threadId.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .failedBeforeWrite(reason: "Codex rejected the message before confirmation.")
        }
    }

    private static func sendTextOnly(
        _ text: String,
        to session: SessionState,
        keepFocusOnHost: Bool,
        onEscDuringSend: @MainActor @escaping () -> Void,
        operationID: String
    ) async -> TerminalAttachmentDeliveryOutcome {
        // This check is intentionally before every PTY/AppleScript route.
        // WindowComposer retains the exact snapshot when this returns false,
        // so an oversized prompt cannot result in a partial terminal write.
        guard TerminalTextPolicy.canSend(text) else {
            logger.error(
                "terminal text rejected before write bytes=\(text.utf8.count, privacy: .public) max=\(TerminalTextPolicy.maximumUTF8Bytes, privacy: .public)"
            )
            return .failedBeforeWrite(reason: "The terminal message exceeds the UTF-8 size limit.")
        }
        // visor-spawned: silent pty write.
        if session.origin == .visorSpawned {
            do {
                try await SpawnedSessionManager.shared.writeMessage(
                    text,
                    to: session.sessionId
                )
                return .delivered
            } catch {
                logger.error("visor-spawn writeMessage failed: \(error.localizedDescription, privacy: .public)")
                return .failedBeforeWrite(reason: "The spawned terminal rejected the message.")
            }
        }

        // tmux: send-keys via the resolved target.
        if let tty = session.tty,
           session.isInTmux,
           let target = await findTmuxTarget(tty: tty, operationID: operationID) {
            guard TerminalProcessIdentityResolver.isVerified(session) else {
                return .failedBeforeWrite(reason: "The terminal process identity is no longer verified.")
            }
            let delivered = await ToolApprovalHandler.shared.sendMessage(
                text,
                to: target,
                operationID: operationID,
                verifyTarget: { TerminalProcessIdentityResolver.isVerified(session) }
            )
            return delivered
                ? .delivered
                : .failedBeforeWrite(reason: "The tmux target rejected the message.")
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
        let outcome: TerminalAttachmentDeliveryOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: TerminalAttachmentDeliveryOutcome
                let route: String
                (result, route) = ProcessExecutor.withOperationID(operationID) {
                    if let adapter = TerminalAdapterRegistry.adapter(for: sessionCopy) {
                        return (
                            adapter.sendTextOutcome(
                                text,
                                toSession: sessionCopy,
                                operationID: operationID
                            ),
                            "registry"
                        )
                    } else if sessionCopy.tty != nil {
                        return (
                            GhosttyScripting.sendInputOutcome(
                                text,
                                toSession: sessionCopy,
                                operationID: operationID
                            ),
                            "ghostty"
                        )
                    } else {
                        return (.failedBeforeWrite(reason: "No verified terminal is connected."), "noTTY")
                    }
                }
                if result.isDelivered {
                    Self.logger.info("submit ok route=\(route, privacy: .public) sid=\(sessionCopy.sessionId.prefix(8), privacy: .public) len=\(text.count, privacy: .public)")
                } else {
                    Self.logger.error("submit FAILED route=\(route, privacy: .public) sid=\(sessionCopy.sessionId.prefix(8), privacy: .public) len=\(text.count, privacy: .public) tty=\(sessionCopy.tty ?? "nil", privacy: .public)")
                }
                continuation.resume(returning: result)
            }
        }

        // `keepFocusOnHost` was the notch-panel-era hook for re-keying
        // the panel after the AppleScript focus-theft window. The notch
        // panel is gone; window mode never sets it, so this path is
        // intentionally a no-op. Kept the parameter as an inert flag
        // so the existing call sites don't need updating; a follow-up
        // pass can drop both it and the dead helpers below.
        _ = keepFocusOnHost
        return outcome
    }

    private static func postImageDeliveryFailure(for session: SessionState) {
        logger.error(
            "image submit FAILED sid=\(session.sessionId.prefix(8), privacy: .public) agent=\(session.agentID.rawValue, privacy: .public)"
        )
        NotificationCenter.default.post(
            name: .cvShowToast,
            object: nil,
            userInfo: [
                "text": "Couldn’t send the image to Pi. Paste it again to retry.",
            ]
        )
    }

    private static func admissionMetadata(
        for attachment: ImageAttachment
    ) -> ImageAttachmentAdmissionMetadata {
        let fileExists = FileManager.default.fileExists(atPath: attachment.url.path)
        let byteCount: Int
        if let values = try? FileManager.default.attributesOfItem(atPath: attachment.url.path),
           let number = values[.size] as? NSNumber {
            byteCount = number.intValue
        } else {
            byteCount = -1
        }
        let data = try? Data(contentsOf: attachment.url)
        let bitmap = data.flatMap(NSBitmapImageRep.init(data:))
        let decodedImage = bitmap == nil ? NSImage(contentsOf: attachment.url) : nil
        return ImageAttachmentAdmissionMetadata(
            id: attachment.id.uuidString,
            byteCount: byteCount,
            width: bitmap?.pixelsWide ?? Int(decodedImage?.size.width ?? 0),
            height: bitmap?.pixelsHigh ?? Int(decodedImage?.size.height ?? 0),
            fileExists: fileExists,
            isDecodable: bitmap != nil || decodedImage != nil
        )
    }

    private static func findTmuxTarget(
        tty: String,
        operationID: String
    ) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }
        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: [
                    "list-panes", "-a", "-F",
                    "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"
                ],
                timeout: SubprocessDeadlinePolicy.appCommand,
                operationID: operationID
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
