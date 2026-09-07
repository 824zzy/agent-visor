import CoreGraphics

public enum NativeMenuPanelTarget: Hashable, Sendable {
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
        usageFrames: [String: CGRect] = [:],
        frontToBack: [NativeMenuPanelTarget] = []
    ) -> NativeMenuPanelTarget {
        for target in frontToBack {
            let frame: CGRect?
            switch target {
            case .session(let id): frame = sessionFrames[id]
            case .usage(let id): frame = usageFrames[id]
            case .overflow: frame = overflowFrame
            case .none: frame = nil
            }
            if contains(point, in: frame) { return target }
        }
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
