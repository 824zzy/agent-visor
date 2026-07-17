import Foundation

public enum NotchMenuContextRefreshPolicy {
    public static func shouldResolveOwner(
        hasContext: Bool,
        contextFrontmostPid: pid_t?,
        observedFrontmostPid: pid_t?,
        contextTargetScreenID: String?,
        observedTargetScreenID: String,
        contextOwnerIsResolved: Bool = true
    ) -> Bool {
        guard hasContext else { return true }
        guard contextTargetScreenID == observedTargetScreenID else { return true }
        guard contextOwnerIsResolved else { return true }
        guard let observedFrontmostPid else { return false }
        return observedFrontmostPid != contextFrontmostPid
    }
}
