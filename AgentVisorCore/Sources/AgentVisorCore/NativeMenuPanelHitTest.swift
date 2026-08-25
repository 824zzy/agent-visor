import CoreGraphics

public enum NativeMenuPanelTarget: Equatable, Sendable {
    case session(String)
    case overflow
    case usage(String)
    case none
}

public enum NativeMenuPanelHitTest {
    public static func resolve(
        point: CGPoint,
        orderedSessionIDs: [String],
        sessionFrames: [String: CGRect],
        overflowFrame: CGRect?,
        orderedUsageIDs: [String] = [],
        usageFrames: [String: CGRect] = [:]
    ) -> NativeMenuPanelTarget {
        for id in orderedSessionIDs where contains(point, in: sessionFrames[id]) {
            return .session(id)
        }
        if contains(point, in: overflowFrame) { return .overflow }
        for id in orderedUsageIDs where contains(point, in: usageFrames[id]) {
            return .usage(id)
        }
        let usageSlotFrame = orderedUsageIDs.compactMap { usageFrames[$0] }
            .reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        if contains(point, in: usageSlotFrame), let id = orderedUsageIDs.first {
            return .usage(id)
        }
        return .none
    }

    private static func contains(_ point: CGPoint, in frame: CGRect?) -> Bool {
        guard let frame else { return false }
        let radius = frame.height / 2
        return CGPath(
            roundedRect: frame,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ).contains(point)
    }
}
