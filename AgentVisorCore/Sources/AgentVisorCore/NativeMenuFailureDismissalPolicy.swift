public enum NativeMenuFailureDismissalPolicy {
    public static func intent(for pill: NativeHelperPill) -> NativeHelperPillActivationIntent? {
        pill.failureAlert == true ? .dismiss : nil
    }
}
