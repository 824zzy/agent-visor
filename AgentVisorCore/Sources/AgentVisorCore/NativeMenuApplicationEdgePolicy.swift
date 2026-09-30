import CoreGraphics

/// Maps one app's accessibility menu items to the display that holds the pills.
/// macOS can expose those items on a different display from the target menu bar.
public enum NativeMenuApplicationEdgePolicy {
    public static func rightEdge(
        targetScreen: CGRect,
        screens: [CGRect],
        menuItemFrames: [CGRect]
    ) -> CGFloat? {
        let measuredScreens = screens.map { screen in
            (
                screen: screen,
                items: menuItemFrames.filter { item in
                    item.width > 0 && item.height > 0
                        && item.origin.x.isFinite && item.origin.y.isFinite
                        && screen.contains(CGPoint(x: item.midX, y: item.midY))
                }
            )
        }
        let source = measuredScreens.first { $0.screen == targetScreen && !$0.items.isEmpty }
            ?? measuredScreens.max { $0.items.count < $1.items.count }
        guard let source, !source.items.isEmpty else { return nil }

        let items = source.items.sorted { $0.minX < $1.minX }
        var maxRight = items[0].maxX
        for index in 1..<items.count {
            if items[index].minX - items[index - 1].maxX > 50 { break }
            maxRight = max(maxRight, items[index].maxX)
        }
        let edge = source.screen == targetScreen
            ? maxRight
            : targetScreen.minX + maxRight - items[0].minX + 10
        guard edge.isFinite, edge > targetScreen.minX, edge < targetScreen.maxX else { return nil }
        return edge
    }
}
