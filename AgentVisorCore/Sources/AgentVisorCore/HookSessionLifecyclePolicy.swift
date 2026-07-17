import Foundation

public enum HookSessionLifecyclePhase: Equatable, Sendable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval
    case compacting
    case ended
}

public enum HookSessionLifecyclePolicy {
    public static func phase(
        event: String,
        reportedStatus: String,
        isTerminalLifecycleStatus: Bool
    ) -> HookSessionLifecyclePhase {
        if event == "PreCompact" { return .compacting }
        if isTerminalLifecycleStatus { return .ended }
        if event == "SessionStart" { return .idle }
        if event == "SubagentStop" { return .processing }
        if event == "StopFailure" { return .waitingForInput }

        switch reportedStatus {
        case "waiting_for_approval": return .waitingForApproval
        case "waiting_for_input": return .waitingForInput
        case "running_tool", "processing", "starting": return .processing
        case "compacting": return .compacting
        default: return .idle
        }
    }
}

public enum HookReadyExpirationPolicy {
    public static func shouldExpire(
        isWaitingForInput: Bool,
        hasHookEvidence: Bool,
        observedAt: TimeInterval,
        now: TimeInterval,
        staleCeiling: TimeInterval = TranscriptPhaseInferrer.defaultStaleCeiling
    ) -> Bool {
        guard isWaitingForInput, hasHookEvidence else { return false }
        return now - observedAt > staleCeiling
    }
}
