public enum NotchMenuOwnerCandidatePolicy {
    public static func canOwnTargetMenu(
        windowLayer: Int,
        isOwnProcess: Bool,
        isOnTargetScreen: Bool,
        isRegularApplication: Bool,
        hasBundleIdentifier: Bool
    ) -> Bool {
        windowLayer == 0
            && !isOwnProcess
            && isOnTargetScreen
            && isRegularApplication
            && hasBundleIdentifier
    }
}
