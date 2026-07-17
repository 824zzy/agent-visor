import Foundation

/// Configuration for the double-tap gesture timing. Production app uses
/// the `.standard` preset; tests inject their own values to keep
/// boundary cases readable.
public struct HotkeyDoubleTapConfig: Equatable, Sendable {
    /// Maximum time between the first tap's release and the second
    /// tap's press. Past this, the second press is treated as a fresh
    /// first tap. Tightened from 300ms to 200ms in v2.1.5 to reduce
    /// mis-fires while still accommodating most users' deliberate
    /// double-tap rhythm.
    public let doubleTapWindow: TimeInterval

    /// Maximum hold duration for a single tap. Longer holds mean the
    /// user is using the key as a modifier (e.g. capitalizing), not
    /// tapping it. 140ms is short enough to filter out Cmd+C/V holds
    /// and shift-during-typing, long enough that a deliberate tap
    /// still passes.
    public let cleanTapMaxDuration: TimeInterval

    public init(doubleTapWindow: TimeInterval, cleanTapMaxDuration: TimeInterval) {
        self.doubleTapWindow = doubleTapWindow
        self.cleanTapMaxDuration = cleanTapMaxDuration
    }

    public static let standard = HotkeyDoubleTapConfig(
        doubleTapWindow: 0.2,
        cleanTapMaxDuration: 0.14
    )
}

/// Pure state machine for detecting a clean double-tap of a single
/// modifier key. Owns no AppKit dependencies; the host app's
/// HotkeyManager translates NSEvent flagsChanged / keyDown events into
/// the inputs below and forwards them here. Lets us unit-test every
/// false-positive killer (window expiry, hold-too-long, chord abort,
/// foreign modifier abort) without standing up an event tap.
public final class HotkeyDoubleTapDetector {

    public enum Input: Equatable, Sendable {
        /// The trigger modifier (alone) just went down.
        case triggerDown(at: Date)
        /// The trigger modifier just released.
        case triggerUp(at: Date)
        /// Another modifier joined the trigger — chord, not tap.
        case foreignModifierHeld(at: Date)
        /// A non-modifier key went down during the gesture.
        case nonModifierKeyDown(at: Date)
    }

    public enum Output: Equatable, Sendable {
        case noChange
        case fired
    }

    private enum State {
        case idle
        case firstDown(at: Date)
        case waitingForSecond(firstUpAt: Date)
        /// Second tap is in progress. We don't fire on this `down` —
        /// we wait for a clean release. That's what kills the
        /// shift-shift-then-`9` false positive: pressing `9` for `(`
        /// aborts before shift releases, so no fire.
        case secondDown(at: Date, firstUpAt: Date)
    }

    public let config: HotkeyDoubleTapConfig
    private var state: State = .idle

    public init(config: HotkeyDoubleTapConfig = .standard) {
        self.config = config
    }

    @discardableResult
    public func handle(_ input: Input) -> Output {
        switch input {
        case .triggerDown(let now):
            return handleTriggerDown(at: now)
        case .triggerUp(let now):
            return handleTriggerUp(at: now)
        case .foreignModifierHeld:
            state = .idle
            return .noChange
        case .nonModifierKeyDown:
            switch state {
            case .firstDown, .waitingForSecond, .secondDown:
                state = .idle
            case .idle:
                break
            }
            return .noChange
        }
    }

    private func handleTriggerDown(at now: Date) -> Output {
        switch state {
        case .idle, .firstDown, .secondDown:
            state = .firstDown(at: now)
        case .waitingForSecond(let firstUpAt):
            if now.timeIntervalSince(firstUpAt) <= config.doubleTapWindow {
                state = .secondDown(at: now, firstUpAt: firstUpAt)
            } else {
                state = .firstDown(at: now)
            }
        }
        return .noChange
    }

    private func handleTriggerUp(at now: Date) -> Output {
        switch state {
        case .firstDown(let downAt):
            let duration = now.timeIntervalSince(downAt)
            if duration <= config.cleanTapMaxDuration {
                state = .waitingForSecond(firstUpAt: now)
            } else {
                state = .idle
            }
            return .noChange
        case .secondDown(let downAt, _):
            let duration = now.timeIntervalSince(downAt)
            state = .idle
            return duration <= config.cleanTapMaxDuration ? .fired : .noChange
        case .idle, .waitingForSecond:
            return .noChange
        }
    }
}
