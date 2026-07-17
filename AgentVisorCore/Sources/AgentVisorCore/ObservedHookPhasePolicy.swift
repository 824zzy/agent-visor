import Foundation

public enum ObservedHookPhasePolicy {
    public enum ReportedPhase: CaseIterable, Equatable, Sendable {
        case idle
        case processing
        case waitingForInput
        case waitingForApproval
        case compacting
        case ended
    }

    public static func shouldApplyHookPhase(
        usesTranscriptPhaseInference: Bool,
        reportedPhase: ReportedPhase,
        isCurrentlyWaitingForApproval: Bool = false
    ) -> Bool {
        guard usesTranscriptPhaseInference else { return true }
        switch reportedPhase {
        case .processing, .compacting, .waitingForApproval, .ended:
            return true
        case .waitingForInput:
            return isCurrentlyWaitingForApproval
        case .idle:
            return false
        }
    }
}
