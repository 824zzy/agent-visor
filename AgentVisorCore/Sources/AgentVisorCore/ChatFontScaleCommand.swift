import Foundation

/// Decode a Cmd-modified keystroke into a shared content font-scale
/// command. Pure decision so Sessions and Chat route through tested logic
/// rather than scattered switch statements. Returns nil for any
/// non-matching event so the host passes it to the focused responder.
public enum ContentFontScaleCommand: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case reset

    /// Decide whether a modified key is a content font-scale gesture.
    /// Command is required; Option and Control are rejected because those
    /// modifier families may own Agent Visor's global session shortcuts.
    /// Shift remains valid for keyboard layouts that produce `+` or `_`.
    public static func decode(
        commandHeld: Bool,
        optionHeld: Bool = false,
        controlHeld: Bool = false,
        charactersIgnoringModifiers: String
    ) -> ContentFontScaleCommand? {
        guard commandHeld, !optionHeld, !controlHeld else { return nil }
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

/// Source compatibility for the original Chat-only name. The command now
/// controls one shared Sessions-and-Chat content scale.
public typealias ChatFontScaleCommand = ContentFontScaleCommand
