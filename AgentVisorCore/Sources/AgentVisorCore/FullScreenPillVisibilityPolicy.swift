import CoreGraphics

public enum FullScreenPillPolicy: String, CaseIterable, Sendable {
    case onDemand
    case alwaysHide
    case alwaysShow

    public var displayLabel: String {
        switch self {
        case .onDemand: return "Show on demand"
        case .alwaysHide: return "Always hide"
        case .alwaysShow: return "Always show"
        }
    }

    public var displayDetail: String {
        switch self {
        case .onDemand: return "Reveal at the top edge or with session shortcuts"
        case .alwaysHide: return "Keep the strip hidden; direct shortcuts still work"
        case .alwaysShow: return "Keep the strip above full-screen apps"
        }
    }

    public static func fromPersistedValue(_ value: String?) -> Self {
        switch value {
        case Self.alwaysHide.rawValue:
            return .alwaysHide
        case Self.alwaysShow.rawValue:
            return .alwaysShow
        case Self.onDemand.rawValue, "media", "never", nil:
            return .onDemand
        default:
            return .onDemand
        }
    }
}

public enum FullScreenPillVisibilityPolicy {
    public static func isVisible(
        isFullScreenActive: Bool,
        policy: FullScreenPillPolicy,
        pointerRevealActive: Bool,
        shortcutRevealActive: Bool,
        popoverPresented: Bool
    ) -> Bool {
        guard isFullScreenActive else { return true }
        if popoverPresented { return true }

        switch policy {
        case .onDemand:
            return pointerRevealActive || shortcutRevealActive
        case .alwaysHide:
            return false
        case .alwaysShow:
            return true
        }
    }
}

public enum FullScreenPillPointerZonePolicy {
    public static let activationDepth: CGFloat = 3
    public static let retentionDepth: CGFloat = 40

    public static func contains(
        pointer: CGPoint,
        screenRect: CGRect,
        isRevealed: Bool
    ) -> Bool {
        let depth = isRevealed ? retentionDepth : activationDepth
        return pointer.x >= screenRect.minX
            && pointer.x < screenRect.maxX
            && pointer.y <= screenRect.maxY
            && pointer.y >= screenRect.maxY - depth
    }
}
