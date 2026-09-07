import Foundation

/// Keeps a menu-bar pill anchored to session identity while activity changes.
/// Tool and message context belongs in status and hover/detail surfaces.
public enum MenuBarPillTitlePolicy {
    public static func title(sessionName: String?, projectName: String) -> String {
        if let sessionName {
            let trimmedName = singleLine(sessionName)
            if !trimmedName.isEmpty {
                return trimmedName
            }
        }
        return singleLine(projectName)
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .lazy
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            .first { !$0.isEmpty } ?? ""
    }
}
