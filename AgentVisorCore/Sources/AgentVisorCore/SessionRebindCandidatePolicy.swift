public enum SessionRebindCandidatePolicy {
    public enum HookEvidence: Equatable, Sendable {
        case ordinary
        case exactSessionStart
        case sessionHeartbeat
    }

    public static func evidence(
        agentID: AgentID,
        lifecycleEvent: String
    ) -> HookEvidence {
        guard agentID == .pi else { return .ordinary }
        switch lifecycleEvent {
        case "SessionStart": return .exactSessionStart
        case PiSessionHeartbeatPolicy.lifecycleEvent: return .sessionHeartbeat
        default: return .ordinary
        }
    }

    public static func excludePidForEndedResurrection(currentPid: Int?) -> Int? {
        currentPid
    }

    public static func shouldResurrectEndedSessionFromHook(
        currentPid: Int?,
        eventPid: Int?,
        evidence: HookEvidence
    ) -> Bool {
        guard let eventPid else { return false }
        if evidence == .exactSessionStart { return true }
        guard let currentPid else { return true }
        return currentPid != eventPid
    }
}
