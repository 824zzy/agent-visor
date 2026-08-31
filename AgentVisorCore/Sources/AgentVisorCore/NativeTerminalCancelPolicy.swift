import Foundation

/// Keeps Terminal.app cancellation fail-closed when focus or either injected
/// key-post operation fails. The native helper owns the concrete CGEvent
/// implementation; this policy is the executable seam used by Core tests.
public enum NativeTerminalCancelPolicy {
    public static func result(focusSucceeded: Bool, keyPostSucceeded: Bool) -> Bool {
        focusSucceeded && keyPostSucceeded
    }
}
