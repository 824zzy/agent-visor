//
//  CodexAppServerStreamBridge.swift
//  AgentVisor
//
//  Drives session PHASE from the Codex app-server notification stream
//  for threads agent-visor is driving (.codexAppServer origin).
//
//  Assistant text deltas are mirrored into SessionStore immediately so
//  app-server driven turns stream in Agent Visor even before the rollout
//  JSONL watcher catches up. Tool calls and command output continue to
//  render through the existing CodexConversationParser / file-watcher
//  path. Lifecycle edges are also synthesized as observe-only hook
//  events so the pill/status stripe flips promptly.
//
//  Installed alongside the approval bridge via
//  CodexAppServerApprovalBridge.install().
//

import Foundation
import os.log
import AgentVisorCore

@MainActor
final class CodexAppServerStreamBridge {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexStreamBridge")

    static let shared = CodexAppServerStreamBridge()

    private init() {}

    func handle(method: String, params: AnyCodableEquatableBox) {
        switch method {
        case CodexAppServerProtocol.NotificationMethod.turnStarted:
            if let userMessage = CodexTurnUserMessageNotification(method: method, params: params) {
                Task {
                    await SessionStore.shared.process(.codexUserMessage(
                        sessionId: userMessage.threadId,
                        itemId: userMessage.itemId,
                        text: userMessage.text,
                        images: userMessage.images.map(Self.chatImage(from:))
                    ))
                }
            }
            phase(params, status: "processing")

        case CodexAppServerProtocol.NotificationMethod.turnCompleted:
            phase(params, status: "waiting_for_input")
            CodexUsageMonitor.shared.refreshAfterTurnCompletion()

        case CodexAppServerProtocol.NotificationMethod.agentMessageDelta:
            if let delta = CodexAssistantDeltaNotification(method: method, params: params) {
                Task {
                    await SessionStore.shared.process(.codexAssistantDelta(
                        sessionId: delta.threadId,
                        itemId: delta.itemId,
                        delta: delta.delta
                    ))
                }
            }

        case CodexAppServerProtocol.NotificationMethod.threadStatusChanged:
            runtimeStatus(params)

        case CodexAppServerProtocol.NotificationMethod.serverRequestResolved:
            if let threadId = params.string("threadId") {
                CodexAppServerApprovalBridge.shared.requestResolvedExternally(
                    sessionId: threadId
                )
            }

        case CodexAppServerProtocol.NotificationMethod.accountRateLimitsUpdated:
            CodexUsageMonitor.shared.handleNotification(params)

        default:
            // reasoning deltas, item lifecycle, output deltas:
            // rendered via the rollout watcher; nothing to do here.
            break
        }
    }

    private func runtimeStatus(_ params: AnyCodableEquatableBox) {
        guard let threadId = params.string("threadId"),
              let status = params.object("status"),
              let statusType = status["type"] as? String else { return }
        let activeFlags = status["activeFlags"] as? [String] ?? []
        switch CodexRuntimeStatusPolicy.phase(
            statusType: statusType,
            activeFlags: activeFlags
        ) {
        case .processing:
            phase(params, status: "processing")
        case .waitingForApproval:
            phase(params, status: "waiting_for_approval")
        case .waitingForInput:
            phase(params, status: "waiting_for_input")
        case .unavailable:
            Task {
                await CodexConnectedRuntimeCoordinator.shared.threadBecameUnavailable(
                    threadId: threadId
                )
            }
        }
    }

    /// Push an observe-only hook event for `threadId` so SessionStore
    /// transitions the phase. Mirrors what agent-visor-codex-state.py emits;
    /// reusing that path keeps a single phase pipeline for Codex.
    private func phase(_ params: AnyCodableEquatableBox, status: String) {
        guard let threadId = params.string("threadId") else { return }
        let event = HookEvent(
            sessionId: threadId,
            cwd: "",
            event: status == "processing" ? "UserPromptSubmit" : "Stop",
            status: status,
            pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
            notificationType: nil, message: nil,
            agent: AgentID.codex.rawValue
        )
        Self.logger.debug("codex stream phase thread=\(threadId.prefix(8), privacy: .public) status=\(status, privacy: .public)")
        Task { await SessionStore.shared.process(.hookReceived(event)) }
    }

    private static func chatImage(from image: CodexParsedImage) -> ChatImageAttachment {
        let source: ChatImageAttachment.Source = {
            switch image.source {
            case .localPath: return .localPath
            case .dataURI: return .dataURI
            }
        }()
        return ChatImageAttachment(source: source, value: image.value)
    }
}
