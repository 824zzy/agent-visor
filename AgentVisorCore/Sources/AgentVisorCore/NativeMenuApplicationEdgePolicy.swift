import CoreGraphics

/// Accepts one complete app menu before mapping it to the display with pills.
public enum NativeMenuApplicationEdgePolicy {
    public static func rightEdge(
        targetScreen: CGRect,
        screens: [CGRect],
        menuItemFrames: [CGRect]
    ) -> CGFloat? {
        guard screens.contains(targetScreen), menuItemFrames.count >= 2 else { return nil }
        let sources = screens.filter { screen in
            menuItemFrames.allSatisfy { item in
                item.width > 0 && item.height > 0
                    && item.minX.isFinite && item.maxX.isFinite
                    && item.minY.isFinite && item.maxY.isFinite
                    && screen.contains(CGPoint(x: item.midX, y: item.midY))
                    && item.minX >= screen.minX && item.maxX <= screen.maxX
            }
        }
        guard sources.count == 1, let source = sources.first else { return nil }
        let items = menuItemFrames.sorted { $0.minX < $1.minX }
        guard let first = items.first, let last = items.last,
              first.minX - source.minX <= 80,
              zip(items, items.dropFirst()).allSatisfy({
                  let gap = $1.minX - $0.maxX
                  return gap >= -0.5 && gap <= 50
              }) else { return nil }

        let width = last.maxX - source.minX
        // A menu crowded against the source display may omit items that would
        // fit on a wider target. Do not transfer that incomplete reading.
        if source != targetScreen, source.maxX - last.maxX < 100 { return nil }
        let edge = targetScreen.minX + width + (source == targetScreen ? 0 : 24)
        guard edge.isFinite, edge > targetScreen.minX, edge < targetScreen.maxX else { return nil }
        return edge
    }
}
