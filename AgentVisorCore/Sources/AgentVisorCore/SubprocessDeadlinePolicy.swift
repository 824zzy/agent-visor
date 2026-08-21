import Foundation

/// How long the app waits for a child process before it gives up.
///
/// Every child process the app starts today waits with no deadline. The wait is
/// a semaphore whose deadline is `distantFuture`, so a child that never exits
/// holds its thread for the life of the app. That is rare but not impossible: a
/// tool can wait on a lock, a network mount can stall, a probe can ask a hung
/// app a question.
///
/// A deadline turns that into a missing answer, which every caller already
/// handles, because a process can also fail or return nothing.
public enum SubprocessDeadlinePolicy {
    /// A read of local state: `ps`, `lsof`, a sqlite query, an app check.
    ///
    /// These finish in milliseconds when the machine is healthy. Five seconds is
    /// far past that, so reaching it means something is wrong, not slow.
    public static let localRead: TimeInterval = 5

    /// A command that acts on another app, such as opening a window or sending
    /// keystrokes. These wait for an app to respond, so they are allowed longer.
    public static let appCommand: TimeInterval = 20

    /// What the caller should do when the deadline passes.
    public enum Outcome: Equatable, Sendable {
        /// The child answered in time.
        case answered
        /// The deadline passed. The child is stopped and there is no answer.
        case gaveUp
    }

    /// Whether a call that has run for `elapsed` has passed its deadline.
    public static func outcome(elapsed: TimeInterval, deadline: TimeInterval) -> Outcome {
        elapsed >= deadline ? .gaveUp : .answered
    }

    /// The deadline for a call, given the caller's own choice.
    ///
    /// A caller may ask for longer or shorter. It may not ask for no deadline,
    /// and it may not ask for zero, which would stop every child before it
    /// started. That is the point of routing the choice through here.
    public static func deadline(requested: TimeInterval?, fallback: TimeInterval = localRead) -> TimeInterval {
        guard let requested, requested > 0 else { return fallback }
        return requested
    }
}
