import Foundation

/// Phase used by the overflow presentation for grouping and status copy.
///
/// The wire phase remains the provider's turn phase. A history attention tier
/// is a menu-only projection for an old Ready row, so it must not erase the
/// Ready phase that drives the native age fade.
public enum NativeMenuDisplayPhase {
    public static func phase(for pill: NativeHelperPill) -> NativeHelperPillPhase {
        guard let attentionTier = pill.attentionTier else { return pill.phase }
        switch attentionTier {
        case .needsYou: return .needsYou
        case .ready, .acknowledgedReady: return .ready
        case .working: return .working
        case .history: return .history
        }
    }
}

/// Keeps native status meaning independent from the menu-only display tier.
/// A known Ready pill may be grouped as Recent while its dot and status copy
/// remain Ready.
public enum NativeMenuStatusPresentation {
    public static func status(for pill: NativeHelperPill) -> String {
        if pill.phase == .ready { return pill.inspector?.status ?? "Ready" }
        return pill.inspector?.status ?? fallbackStatus(for: NativeMenuDisplayPhase.phase(for: pill))
    }

    public static func tone(for pill: NativeHelperPill) -> NativeHelperPillPhase {
        switch pill.inspector?.status {
        case "Needs attention", "Needs you": return .needsYou
        case "Ready": return .ready
        case "Working": return .working
        case "Closed", "Status unavailable", "Ended", "Recent", "Historical": return .history
        default: return pill.phase
        }
    }

    private static func fallbackStatus(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: return "Needs attention"
        case .ready: return "Ready"
        case .working: return "In progress"
        case .history: return "History"
        }
    }
}
