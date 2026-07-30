public enum PiSessionHeartbeatPolicy {
    public enum Disposition: Equatable, Sendable {
        case notHeartbeat
        case ignore
        case preserveLiveState
        case reattachIdle
    }

    public static let lifecycleEvent = "SessionHeartbeat"

    public static func isHeartbeat(
        agentID: AgentID,
        lifecycleEvent: String
    ) -> Bool {
        agentID == .pi && lifecycleEvent == self.lifecycleEvent
    }

    public static func disposition(
        agentID: AgentID,
        lifecycleEvent: String,
        hasExistingSession: Bool,
        existingSessionEnded: Bool,
        existingPid: Int?,
        eventPid: Int?,
        hasDifferentLiveSessionWithEventPid: Bool
    ) -> Disposition {
        guard isHeartbeat(agentID: agentID, lifecycleEvent: lifecycleEvent) else {
            return .notHeartbeat
        }
        guard eventPid != nil, !hasDifferentLiveSessionWithEventPid else {
            return .ignore
        }
        guard hasExistingSession else {
            return .reattachIdle
        }
        guard existingSessionEnded else {
            return .preserveLiveState
        }

        let evidence = SessionRebindCandidatePolicy.evidence(
            agentID: agentID,
            lifecycleEvent: lifecycleEvent
        )
        return SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook(
            currentPid: existingPid,
            eventPid: eventPid,
            evidence: evidence
        ) ? .reattachIdle : .ignore
    }
}
