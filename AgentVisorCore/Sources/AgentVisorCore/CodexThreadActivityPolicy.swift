import Foundation

public enum CodexThreadActivityPolicy {
    public static func effectiveUpdatedAt(
        sqliteUpdatedAt: Int,
        rolloutModifiedAt: Int?
    ) -> Int {
        guard let rolloutModifiedAt else {
            return sqliteUpdatedAt
        }
        return max(sqliteUpdatedAt, rolloutModifiedAt)
    }
}
