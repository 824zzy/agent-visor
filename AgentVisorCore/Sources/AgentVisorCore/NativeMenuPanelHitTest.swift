import CoreGraphics

public enum NativeMenuPanelTarget: Equatable, Sendable {
    case session(String)
    case overflow
    case none
}

public enum NativeMenuPanelHitTest {
    public static func resolve(
        point: CGPoint,
        orderedSessionIDs: [String],
        sessionFrames: [String: CGRect],
        overflowFrame: CGRect?
    ) -> NativeMenuPanelTarget {
        for id in orderedSessionIDs {
            guard let frame = sessionFrames[id] else { continue }
            let radius = frame.height / 2
            if CGPath(
                roundedRect: frame,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ).contains(point) {
                return .session(id)
            }
        }
        if let overflowFrame {
            let radius = overflowFrame.height / 2
            if CGPath(
                roundedRect: overflowFrame,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ).contains(point) {
                return .overflow
            }
        }
        return .none
    }
}
