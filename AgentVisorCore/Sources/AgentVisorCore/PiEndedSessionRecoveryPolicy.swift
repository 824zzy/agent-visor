import Foundation

/// An ended Pi session may keep running when a best-effort lifecycle event
/// arrives out of order or a later lifecycle event is dropped. Recover only
/// from stronger combined evidence: the same process is still live and its
/// transcript began a new turn after the ended observation.
public enum PiEndedSessionRecoveryPolicy {
    public static func shouldRecover(
        isEnded: Bool,
        hasLiveProcess: Bool,
        transcriptModifiedAt: TimeInterval,
        endedObservedAt: TimeInterval,
        turnMarker: TurnMarker
    ) -> Bool {
        isEnded
            && hasLiveProcess
            && transcriptModifiedAt > endedObservedAt
            && turnMarker == .started
    }
}
