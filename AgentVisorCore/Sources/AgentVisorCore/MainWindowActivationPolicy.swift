import Foundation

public enum MainWindowActivationReason: Equatable, Sendable {
    case appLaunch
    case appReopen
    case hotkey
    case settings
    case menuBarStatusItem
    case overflowPill
    case approvalNotificationTap
    case pendingApprovalDetected
}

public enum MainWindowActivationAction: Equatable, Sendable {
    case show
    case toggle
    case ignore
}

public enum MainWindowActivationPolicy {
    public static func action(for reason: MainWindowActivationReason) -> MainWindowActivationAction {
        switch reason {
        case .appLaunch, .pendingApprovalDetected:
            return .ignore
        case .hotkey:
            return .toggle
        case .appReopen, .settings, .menuBarStatusItem, .overflowPill, .approvalNotificationTap:
            return .show
        }
    }
}
