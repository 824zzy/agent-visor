import CoreGraphics

/// Horizontal geometry for the centered primary-content rail shared by
/// the Sessions browser and Chat.
public struct MainContentRailGeometry: Equatable, Sendable {
    public let leading: CGFloat
    public let width: CGFloat

    public init(leading: CGFloat, width: CGFloat) {
        self.leading = leading
        self.width = width
    }
}

/// Resolves one stable rail: 28pt minimum gutters on constrained windows,
/// then a centered 980pt ceiling when more width is available.
public enum MainContentRailLayout {
    public static let maximumWidth: CGFloat = 980
    public static let horizontalInset: CGFloat = 28

    public static func resolve(containerWidth: CGFloat) -> MainContentRailGeometry {
        let containerWidth = max(0, containerWidth)
        let availableWidth = max(0, containerWidth - horizontalInset * 2)
        let railWidth = min(maximumWidth, availableWidth)
        return MainContentRailGeometry(
            leading: (containerWidth - railWidth) / 2,
            width: railWidth
        )
    }
}
