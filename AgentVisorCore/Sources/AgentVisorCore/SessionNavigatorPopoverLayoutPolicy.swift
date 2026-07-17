import Foundation

public enum SessionNavigatorPopoverLayoutPolicy {
    public static let preferredWidth: Double = 560
    public static let minimumWidth: Double = 360
    public static let screenEdgeInset: Double = 80
    public static let maximumHeight: Double = 520

    public static func width(forVisibleScreenWidth visibleScreenWidth: Double?) -> Double {
        guard let visibleScreenWidth, visibleScreenWidth.isFinite, visibleScreenWidth > 0 else {
            return preferredWidth
        }

        let maximumAllowedWidth = max(minimumWidth, visibleScreenWidth - screenEdgeInset)
        return min(preferredWidth, maximumAllowedWidth)
    }
}
