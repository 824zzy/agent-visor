public enum TerminalFocusVerificationPolicy {
    public static func isSuccessful(
        selectedTargetMatches: Bool,
        hostIsFrontmost: Bool
    ) -> Bool {
        selectedTargetMatches && hostIsFrontmost
    }
}
