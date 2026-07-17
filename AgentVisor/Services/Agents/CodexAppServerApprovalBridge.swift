//
//  CodexAppServerApprovalBridge.swift
//  AgentVisor
//
//  Bridges Codex app-server approval requests onto agent-visor's
//  existing approval surface. This is the headline feature of driving a
//  Codex thread end-to-end: when the engine wants to run a command,
//  apply a patch, or edit files, it sends a server→client approval
//  request over the JSON-RPC channel; we surface it as a
//  `.waitingForApproval` phase so the SAME approval bar the user knows
//  from claude-code appears, capture allow/deny, and send Codex's
//  decision back.
//
//  Flow:
//    1. CodexAppServerClient.onServerRequest(id, method, params) →
//       bridge.handle(...) — records the pending request (rpc id +
//       method, keyed by threadId) and pushes a synthetic hook event so
//       SessionStore moves the session to .waitingForApproval.
//    2. The approval bar's onApprove/onDeny calls
//       bridge.resolve(sessionId:intent:) — maps the intent to Codex's
//       per-request decision (CodexApprovalDecisionMapper) and replies
//       on the client, then clears the pending entry.
//
//  Notifications (streaming deltas, turn lifecycle) are handled
//  separately by CodexAppServerStreamBridge; this file owns approvals
//  only. Both are installed via `install()` at app launch.
//

import Foundation
import os.log
import AgentVisorCore

@MainActor
final class CodexAppServerApprovalBridge {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexApprovalBridge")

    static let shared = CodexAppServerApprovalBridge()

    enum RequestSource: Sendable {
        case managed
        case connected
    }

    /// A Codex approval request awaiting the user's decision.
    private struct Pending {
        let rpcId: CodexRPCID
        let method: String
        let kind: CodexAppServerProtocol.ServerRequestMethod.Kind
        let toolUseId: String
        let requestParams: AnyCodableEquatableBox
        let source: RequestSource
    }

    /// threadId (== sessionId) → pending approval. One in-flight approval
    /// per thread at a time, matching Codex's turn model.
    private var pendingByThread: [String: Pending] = [:]

    private init() {}

    // MARK: - Wiring

    /// Install the bridge's handlers on the shared client. Idempotent;
    /// call once at app launch (AppDelegate).
    func install() {
        let handlers = CodexAppServerHandlers(
            onNotification: { method, params in
                await MainActor.run {
                    CodexAppServerStreamBridge.shared.handle(method: method, params: params)
                }
            },
            onServerRequest: { id, method, params in
                await MainActor.run {
                    CodexAppServerApprovalBridge.shared.handle(
                        id: id,
                        method: method,
                        params: params,
                        source: .managed
                    )
                }
            }
        )
        Task { await CodexAppServerClient.shared.setHandlers(handlers) }
    }

    // MARK: - Inbound request

    func handleConnected(id: CodexRPCID, method: String, params: AnyCodableEquatableBox) {
        handle(id: id, method: method, params: params, source: .connected)
    }

    private func handle(
        id: CodexRPCID,
        method: String,
        params: AnyCodableEquatableBox,
        source: RequestSource
    ) {
        let kind = CodexAppServerProtocol.ServerRequestMethod.kind(method)
        guard kind != .unsupported else {
            Self.logger.error("unsupported request reached approval bridge method=\(method, privacy: .public)")
            respondError(source: source, id: id, message: "unsupported by agent-visor: \(method)")
            return
        }
        guard let threadId = params.string("threadId") else {
            Self.logger.error("codex request missing threadId; rejecting")
            respondError(source: source, id: id, message: "missing threadId")
            return
        }
        // itemId is the closest analog to a tool-use id; fall back to the
        // turnId so the PermissionContext always has a stable key.
        let toolUseId = params.string("requestId")
            ?? params.string("itemId")
            ?? params.string("turnId")
            ?? Self.rpcIdString(id)
        let toolName = Self.toolName(for: method)
        let toolInput = Self.toolInput(method: method, params: params)
        if kind == .userInput, toolInput?["questions"] == nil {
            Self.logger.error("requestUserInput missing questions; rejecting")
            respondError(source: source, id: id, message: "missing questions")
            return
        }
        guard pendingByThread[threadId] == nil else {
            Self.logger.error(
                "codex request arrived while another decision is pending thread=\(threadId.prefix(8), privacy: .public)"
            )
            respondError(
                source: source,
                id: id,
                message: "another user decision is already pending"
            )
            return
        }

        pendingByThread[threadId] = Pending(
            rpcId: id,
            method: method,
            kind: kind,
            toolUseId: toolUseId,
            requestParams: params,
            source: source
        )
        Self.logger.info("codex request pending thread=\(threadId.prefix(8), privacy: .public) method=\(method, privacy: .public) kind=\(String(describing: kind), privacy: .public)")

        // Push a synthetic hook event so SessionStore transitions the
        // session to .waitingForApproval — reusing the observe-only
        // `waiting_for_approval` status path that already drives the
        // pill/sidebar/approval-bar for Codex.
        let event = HookEvent(
            sessionId: threadId,
            cwd: "",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            pid: nil,
            tty: nil,
            tool: toolName,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil,
            agent: AgentID.codex.rawValue
        )
        Task { await SessionStore.shared.process(.hookReceived(event)) }
    }

    // MARK: - Outbound decision

    /// True when this session has a Codex approval awaiting decision —
    /// used by the UI to route onApprove/onDeny here instead of the
    /// claude-code monitor.
    func hasPendingApproval(sessionId: String) -> Bool {
        pendingByThread[sessionId]?.kind == .approval
    }

    func hasPendingUserInput(sessionId: String) -> Bool {
        pendingByThread[sessionId]?.kind == .userInput
    }

    func requestResolvedExternally(sessionId: String) {
        guard let pending = pendingByThread.removeValue(forKey: sessionId) else { return }
        finishPending(sessionId: sessionId, pending: pending, status: "processing")
    }

    func connectedTransportDisconnected() {
        let orphanedThreadIds = pendingByThread.compactMap { threadId, pending in
            if case .connected = pending.source { return threadId }
            return nil
        }
        for threadId in orphanedThreadIds {
            pendingByThread.removeValue(forKey: threadId)
        }
        if !orphanedThreadIds.isEmpty {
            Self.logger.info(
                "cleared \(orphanedThreadIds.count, privacy: .public) pending requests after connected transport loss"
            )
        }
    }

    /// Resolve the pending Codex approval for `sessionId` with the user's
    /// intent. Maps to Codex's per-request decision vocabulary and sends
    /// the JSON-RPC response. Also clears the `.waitingForApproval`
    /// phase by reporting the turn back to processing (Codex continues
    /// the turn once it has the decision).
    func resolve(sessionId: String, intent: CodexApprovalIntent) {
        guard let pending = pendingByThread[sessionId] else {
            Self.logger.error("resolve: no pending approval for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        guard pending.kind == .approval else {
            Self.logger.error("resolve: pending request is not approval for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        pendingByThread.removeValue(forKey: sessionId)
        guard let result = CodexApprovalDecisionMapper.result(
            for: pending.method,
            intent: intent,
            requestParams: pending.requestParams
        ) else {
            // Shouldn't happen — we only register handled methods — but
            // fail safe by rejecting so Codex falls back.
            respondError(source: pending.source, id: pending.rpcId, message: "unmapped approval")
            return
        }
        Self.logger.info("codex approval resolve thread=\(sessionId.prefix(8), privacy: .public) intent=\(String(describing: intent), privacy: .public)")
        respond(source: pending.source, id: pending.rpcId, result: result)

        // Move the session out of waitingForApproval. allow → the engine
        // resumes the turn (processing); deny/cancel → idle-ish. We use a
        // processing hook for allow and waiting_for_input for deny so the
        // UI reflects the outcome until the rollout stream catches up.
        let status = (intent == .deny || intent == .cancel) ? "waiting_for_input" : "processing"
        finishPending(sessionId: sessionId, pending: pending, status: status)
    }

    func resolveUserInput(sessionId: String, answersByQuestionId: [String: [String]]) {
        guard let pending = pendingByThread[sessionId] else {
            Self.logger.error("resolveUserInput: no pending user input for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        guard pending.kind == .userInput else {
            Self.logger.error("resolveUserInput: pending request is not user input for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        pendingByThread.removeValue(forKey: sessionId)
        let result = CodexApprovalDecisionMapper.userInputResult(answersByQuestionId: answersByQuestionId)
        Self.logger.info("codex user input resolve thread=\(sessionId.prefix(8), privacy: .public) answers=\(answersByQuestionId.count, privacy: .public)")
        respond(source: pending.source, id: pending.rpcId, result: result)
        finishPending(sessionId: sessionId, pending: pending, status: "processing")
    }

    func cancelUserInput(sessionId: String) {
        guard let pending = pendingByThread[sessionId] else {
            Self.logger.error("cancelUserInput: no pending user input for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        guard pending.kind == .userInput else {
            Self.logger.error("cancelUserInput: pending request is not user input for \(sessionId.prefix(8), privacy: .public)")
            return
        }
        pendingByThread.removeValue(forKey: sessionId)
        respondError(source: pending.source, id: pending.rpcId, message: "cancelled by user")
        finishPending(sessionId: sessionId, pending: pending, status: "waiting_for_input")
    }

    // MARK: - Display helpers

    /// Friendly tool label for the approval bar header per request type.
    private static func toolName(for method: String) -> String {
        switch method {
        case CodexAppServerProtocol.ServerRequestMethod.commandExecutionApproval,
             CodexAppServerProtocol.ServerRequestMethod.execCommandApproval:
            return "Run command"
        case CodexAppServerProtocol.ServerRequestMethod.fileChangeApproval,
             CodexAppServerProtocol.ServerRequestMethod.applyPatchApproval:
            return "Apply changes"
        case CodexAppServerProtocol.ServerRequestMethod.permissionsApproval:
            return "Grant permissions"
        case CodexAppServerProtocol.ServerRequestMethod.requestUserInput:
            return "AskUserQuestion"
        default:
            return "Approve"
        }
    }

    /// Surface the request's salient fields as the approval bar's input
    /// preview (command text, reason). Best-effort — shapes vary by
    /// request type.
    private static func toolInput(method: String, params: AnyCodableEquatableBox) -> [String: AnyCodable]? {
        var out: [String: AnyCodable] = [:]
        if let command = params.string("command") { out["command"] = AnyCodable(command) }
        if let reason = params.string("reason") { out["reason"] = AnyCodable(reason) }
        if let permissions = params.object("permissions") { out["permissions"] = AnyCodable(permissions) }
        if method == CodexAppServerProtocol.ServerRequestMethod.requestUserInput,
           let questions = params.dictionary?["questions"] {
            out["questions"] = AnyCodable(questions)
        }
        return out.isEmpty ? nil : out
    }

    private static func rpcIdString(_ id: CodexRPCID) -> String {
        switch id {
        case .int(let value): return "rpc-\(value)"
        case .string(let value): return value
        }
    }

    private func respond(
        source: RequestSource,
        id: CodexRPCID,
        result: [String: AnyCodable]
    ) {
        switch source {
        case .managed:
            Task { await CodexAppServerClient.shared.respond(id: id, result: result) }
        case .connected:
            Task { @MainActor in
                await CodexConnectedRuntimeCoordinator.shared.respond(id: id, result: result)
            }
        }
    }

    private func respondError(
        source: RequestSource,
        id: CodexRPCID,
        message: String
    ) {
        switch source {
        case .managed:
            Task { await CodexAppServerClient.shared.respondError(id: id, message: message) }
        case .connected:
            Task { @MainActor in
                await CodexConnectedRuntimeCoordinator.shared.respondError(id: id, message: message)
            }
        }
    }

    private func finishPending(sessionId: String, pending: Pending, status: String) {
        let event = HookEvent(
            sessionId: sessionId, cwd: "", event: "PostToolUse", status: status,
            pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: pending.toolUseId,
            notificationType: nil, message: nil, agent: AgentID.codex.rawValue
        )
        Task { await SessionStore.shared.process(.hookReceived(event)) }
    }
}
