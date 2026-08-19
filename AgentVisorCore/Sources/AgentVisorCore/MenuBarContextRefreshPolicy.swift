import Foundation

public enum MenuBarContextRefreshPolicy {
    public static func shouldResolveOwner(
        hasContext: Bool,
        contextFrontmostPid: pid_t?,
        observedFrontmostPid: pid_t?,
        contextTargetScreenID: String?,
        observedTargetScreenID: String,
        contextOwnerPid: pid_t? = nil,
        observedOwnerPid: pid_t? = nil,
        observedOwnerIsResolved: Bool = false,
        contextOwnerIsResolved: Bool = true
    ) -> Bool {
        guard hasContext else { return true }
        guard contextTargetScreenID == observedTargetScreenID else { return true }
        guard contextOwnerIsResolved else { return true }
        guard let observedFrontmostPid else { return false }
        guard observedFrontmostPid == contextFrontmostPid else { return true }
        return observedOwnerIsResolved && observedOwnerPid != contextOwnerPid
    }
}
