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

    /// Decides whether a fallback disk/process *discovery* match may be
    /// admitted to the store. Creation-time discovery can only ever pair a
    /// live Pi process with its startup transcript; once that process resumes
    /// another session in-process, discovery keeps re-finding the stale
    /// startup transcript for the same PID. Reject the discovered row when its
    /// live PID already belongs to a different non-ended session so the
    /// authoritative hook-tracked owner is never shadowed by a ghost row.
    ///
    /// Historical discovery (no PID) and providers that intentionally share a
    /// host process across sessions are never gated here.
    public static func admitsDiscoveredSession(
        agentID: AgentID,
        discoveredPid: Int?,
        pidOwnedByOtherLiveSession: Bool
    ) -> Disposition {
        guard agentID == .pi, discoveredPid != nil else { return .accept }
        return pidOwnedByOtherLiveSession ? .ignoreCompetingRuntime : .accept
    }
}
