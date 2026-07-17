//
//  CodexApprovalDecisionMapper.swift
//  AgentVisorCore
//
//  Maps agent-visor's user-facing approval intent (allow / allow-for-
//  session / deny / cancel) onto the concrete `result` payload each
//  Codex app-server approval request expects. Codex uses a DIFFERENT
//  decision vocabulary per request type:
//
//    item/commandExecution/requestApproval → CommandExecutionApprovalDecision
//        accept | acceptForSession | decline | cancel   (+ amendment objects)
//    item/fileChange/requestApproval       → FileChangeApprovalDecision
//        accept | acceptForSession | decline | cancel
//    item/permissions/requestApproval      → { permissions, scope, strictAutoReview }
//    execCommandApproval / applyPatchApproval → ReviewDecision
//        approved | approved_for_session | denied | abort   (+ amendment objects)
//    item/tool/requestUserInput            → { answers: { id: { answers:[…] } } }
//
//  This file owns the vocabulary so the app-side bridge only thinks in
//  agent-visor terms. Pure / value-in-value-out → unit-testable.
//

import Foundation

/// agent-visor's normalized approval intent. `allow`/`deny` are the two
/// the approval bar produces today; `allowForSession` backs a future
/// "don't ask again", and `cancel` maps to deny-and-interrupt where the
/// request type distinguishes it (otherwise it folds into deny).
public enum CodexApprovalIntent: Equatable, Sendable {
    case allow
    case allowForSession
    case deny
    case cancel
}

public enum CodexApprovalDecisionMapper {
    /// Build the JSON-RPC `result` object to answer `method` with
    /// `intent`. Returns nil for a method we don't know how to answer
    /// (the transport then rejects it with a JSON-RPC error rather than
    /// guessing). `[String: AnyCodable]` so it drops straight into
    /// `CodexRPCResponseOut`.
    public static func result(
        for method: String,
        intent: CodexApprovalIntent,
        requestParams: AnyCodableEquatableBox? = nil
    ) -> [String: AnyCodable]? {
        switch method {
        case CodexAppServerProtocol.ServerRequestMethod.commandExecutionApproval:
            return ["decision": AnyCodable(commandExecutionDecision(intent))]

        case CodexAppServerProtocol.ServerRequestMethod.fileChangeApproval:
            return ["decision": AnyCodable(fileChangeDecision(intent))]

        case CodexAppServerProtocol.ServerRequestMethod.permissionsApproval:
            return permissionsDecision(intent, requestParams: requestParams)

        case CodexAppServerProtocol.ServerRequestMethod.execCommandApproval,
             CodexAppServerProtocol.ServerRequestMethod.applyPatchApproval:
            return ["decision": AnyCodable(reviewDecision(intent))]

        default:
            return nil
        }
    }

    // MARK: - Per-type vocabularies

    /// CommandExecutionApprovalDecision (string variants only — we never
    /// emit the execpolicy/network amendment objects).
    static func commandExecutionDecision(_ intent: CodexApprovalIntent) -> String {
        switch intent {
        case .allow:           return "accept"
        case .allowForSession: return "acceptForSession"
        case .deny:            return "decline"
        case .cancel:          return "cancel"
        }
    }

    /// FileChangeApprovalDecision — same string set as command execution.
    static func fileChangeDecision(_ intent: CodexApprovalIntent) -> String {
        switch intent {
        case .allow:           return "accept"
        case .allowForSession: return "acceptForSession"
        case .deny:            return "decline"
        case .cancel:          return "cancel"
        }
    }

    /// ReviewDecision — used by the legacy exec/applyPatch approval
    /// requests. Different spelling: `approved` / `approved_for_session`
    /// / `denied` / `abort`.
    static func reviewDecision(_ intent: CodexApprovalIntent) -> String {
        switch intent {
        case .allow:           return "approved"
        case .allowForSession: return "approved_for_session"
        case .deny:            return "denied"
        case .cancel:          return "abort"
        }
    }

    /// PermissionsRequestApprovalResponse. Approval grants the requested
    /// permission profile; denial/cancel grants an empty profile.
    static func permissionsDecision(
        _ intent: CodexApprovalIntent,
        requestParams: AnyCodableEquatableBox?
    ) -> [String: AnyCodable] {
        let requested = requestParams?.object("permissions") ?? [:]
        let granted: [String: Any] = (intent == .allow || intent == .allowForSession) ? requested : [:]
        let scope = (intent == .allowForSession) ? "session" : "turn"
        return [
            "permissions": AnyCodable(granted),
            "scope": AnyCodable(scope),
        ]
    }

    /// Answer payload for `item/tool/requestUserInput` (Codex's
    /// AskUserQuestion analog). Maps each questionId to the chosen
    /// answer string(s):  `{ answers: { <id>: { answers: [<choice>] } } }`.
    public static func userInputResult(
        answersByQuestionId: [String: [String]]
    ) -> [String: AnyCodable] {
        let answers = answersByQuestionId.mapValues { choices in
            AnyCodable(["answers": choices])
        }
        return ["answers": AnyCodable(answers.mapValues { $0.value })]
    }
}
