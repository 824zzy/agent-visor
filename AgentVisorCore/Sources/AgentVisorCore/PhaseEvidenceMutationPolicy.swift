import Foundation

public enum PhaseEvidenceMutationPolicy {
    public static func didChange(
        currentSource: String?,
        currentObservedAt: TimeInterval?,
        newSource: String,
        newObservedAt: TimeInterval
    ) -> Bool {
        currentSource != newSource || currentObservedAt != newObservedAt
    }
}
