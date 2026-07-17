import Foundation

/// Decode a Cmd-modified keystroke into a chat font-scale command.
/// Pure decision so the keystroke handler in Window/Notch chat
/// views routes through tested logic rather than scattered switch
/// statements. Returns nil for any non-matching event so the host
/// passes the keystroke through to the focused responder.
public enum ChatFontScaleCommand: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case reset

    /// Decide whether `(commandHeld, charactersIgnoringModifiers)`
    /// is a font-scale gesture. Caller is responsible for checking
    /// that the Command modifier is held — passing
    /// `commandHeld: false` always returns nil so the predicate
    /// can be used as a single guard at the call site.
    public static func decode(commandHeld: Bool, charactersIgnoringModifiers: String) -> ChatFontScaleCommand? {
        guard commandHeld else { return nil }
        switch charactersIgnoringModifiers {
        case "=", "+":
            return .zoomIn
        case "-", "_":
            return .zoomOut
        case "0":
            return .reset
        default:
            return nil
        }
    }

    /// Apply this command to a current scale value, returning the
    /// next clamped value. Pure: no AppStorage / UserDefaults
    /// touched here. Caller persists the result.
    public func apply(to currentScale: Double, step: Double, min minValue: Double, max maxValue: Double) -> Double {
        let next: Double
        switch self {
        case .zoomIn:  next = currentScale + step
        case .zoomOut: next = currentScale - step
        case .reset:   next = 1.0
        }
        // Clamp + round to one decimal so successive presses don't
        // accumulate floating-point drift (0.1 + 0.1 + 0.1 → 0.30000…).
        let clamped = Swift.min(Swift.max(next, minValue), maxValue)
        return (clamped * 10).rounded() / 10
    }
}
