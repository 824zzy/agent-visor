import Foundation

/// Placement phase used by the overflow presentation for grouping.
///
/// This menu-only projection does not define lifecycle status or tone;
/// `NativeMenuStatusPresentation` keeps those meanings tied to explicit
/// lifecycle evidence. A history attention tier may regroup an old Ready row
/// without changing its Ready lifecycle status or semantic tone.
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
        if let lifecycleStatus = pill.lifecycleStatus {
            return label(for: lifecycleStatus)
        }
        return legacyPresentation(for: pill.inspector?.status, phase: pill.phase).label
    }

    public static func tone(for pill: NativeHelperPill) -> NativeHelperPillPhase {
        if let lifecycleStatus = pill.lifecycleStatus {
            return tone(for: lifecycleStatus)
        }
        return legacyPresentation(for: pill.inspector?.status, phase: pill.phase).tone
    }

    private static func label(for lifecycleStatus: NativeHelperLifecycleStatus) -> String {
        switch lifecycleStatus {
        case .needsYou: return "Needs you"
        case .ready: return "Ready"
        case .working: return "Working"
        case .closed: return "Closed"
        case .unavailable: return "Status unavailable"
        case .historical: return "Historical"
        }
    }

    private static func tone(for lifecycleStatus: NativeHelperLifecycleStatus) -> NativeHelperPillPhase {
        switch lifecycleStatus {
        case .needsYou: return .needsYou
        case .ready: return .ready
        case .working: return .working
        case .closed, .unavailable, .historical: return .history
        }
    }

    private static func fallbackStatus(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: return "Needs you"
        case .ready: return "Ready"
        case .working: return "Working"
        case .history: return "Historical"
        }
    }

    private static func legacyPresentation(
        for inspectorStatus: String?,
        phase: NativeHelperPillPhase
    ) -> (label: String, tone: NativeHelperPillPhase) {
        switch inspectorStatus?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Needs attention", "Needs you": return ("Needs you", .needsYou)
        case "Ready", "Ready to continue": return ("Ready", .ready)
        case "Working", "In progress": return ("Working", .working)
        case "Closed", "Ended": return ("Closed", .history)
        case "Status unavailable": return ("Status unavailable", .history)
        case "Recent", "Historical": return ("Historical", .history)
        default:
            return (fallbackStatus(for: phase), phase)
        }
    }
}
