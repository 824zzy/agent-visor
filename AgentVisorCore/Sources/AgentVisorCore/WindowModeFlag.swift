import Foundation

/// Phase-0 feature flag that gates the experimental window-mode UI
/// (sidebar + chat split window) behind an env var. While this is
/// false the legacy notch panel remains the only surface; when true,
/// `AppDelegate` boots the new `MainWindow` alongside (Phases 0–4) or
/// instead of (Phase 5+) the notch.
///
/// Pure value, parameterised on `[String: String]` so it stays
/// testable without `ProcessInfo` mocking.
public enum WindowModeFlag {
    public static let envKey = "AV_WINDOW_MODE"

    public static func isEnabled(in environment: [String: String]) -> Bool {
        guard let raw = environment[envKey] else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    public static func isEnabled() -> Bool {
        isEnabled(in: ProcessInfo.processInfo.environment)
    }
}
