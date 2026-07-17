import CoreGraphics

public enum TransientPopoverHitRegionPolicy {
    public static func isInside(
        eventWindowMatches: Bool,
        screenPoint: CGPoint,
        visiblePopoverFrames: [CGRect]
    ) -> Bool {
        eventWindowMatches || visiblePopoverFrames.contains { $0.contains(screenPoint) }
    }
}
