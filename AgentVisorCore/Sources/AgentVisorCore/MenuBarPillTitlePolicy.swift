import Foundation

/// Keeps a menu-bar pill anchored to session identity while activity changes.
/// Tool and message context belongs in status and hover/detail surfaces.
public enum MenuBarPillTitlePolicy {
    public static func title(sessionName: String?, projectName: String) -> String {
        if let sessionName {
            let trimmedName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                return trimmedName
            }
        }
        return projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
