public enum SessionRebindCandidatePolicy {
    public static func excludePidForEndedResurrection(currentPid: Int?) -> Int? {
        currentPid
    }

    public static func shouldResurrectEndedSessionFromHook(
        currentPid: Int?,
        eventPid: Int?
    ) -> Bool {
        guard let eventPid else { return false }
        guard let currentPid else { return true }
        return currentPid != eventPid
    }
}
