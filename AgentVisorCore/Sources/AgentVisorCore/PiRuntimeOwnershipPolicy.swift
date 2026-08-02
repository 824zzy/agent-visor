/// Keeps one exact live runtime attached to each durable Pi session.
/// A competing runtime cannot change lifecycle or routing until the owner exits.
public enum PiRuntimeOwnershipPolicy {
    public enum Disposition: Equatable, Sendable {
        case accept
        case ignoreCompetingRuntime
    }

    public static func disposition(
        agentID: AgentID,
        hasExistingSession: Bool,
        existingPid: Int?,
        existingOwnerIsAlive: Bool,
        eventPid: Int?
    ) -> Disposition {
        guard agentID == .pi,
              hasExistingSession,
              let existingPid,
              existingPid > 0,
              existingOwnerIsAlive else {
            return .accept
        }
        return eventPid == existingPid ? .accept : .ignoreCompetingRuntime
    }
}
