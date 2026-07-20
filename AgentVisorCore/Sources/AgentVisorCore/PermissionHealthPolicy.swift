public enum AccessibilityFunctionalProbe: Equatable, Sendable {
    case notRun
    case passed
    case failed
}

public enum PermissionHealth: Equatable, Sendable {
    case needsAccessibility
    case verifying
    case needsRepair
    case ready
}

public enum PermissionHealthPolicy {
    public static func evaluate(
        accessibilityTrusted: Bool,
        functionalProbe: AccessibilityFunctionalProbe
    ) -> PermissionHealth {
        guard accessibilityTrusted else {
            return .needsAccessibility
        }

        switch functionalProbe {
        case .passed:
            return .ready
        case .failed:
            return .needsRepair
        case .notRun:
            return .verifying
        }
    }

    public static func requiresRecoveryWork(
        from previous: PermissionHealth,
        to current: PermissionHealth
    ) -> Bool {
        previous != .ready && current == .ready
    }
}

public enum PermissionSetupAction: Equatable, Sendable {
    case requestAccessibility
    case openAccessibilitySettings
    case revealRunningApp
    case none
}

public enum PermissionSetupPolicy {
    public static func primaryAction(for health: PermissionHealth) -> PermissionSetupAction {
        switch health {
        case .needsAccessibility:
            return .requestAccessibility
        case .needsRepair:
            return .openAccessibilitySettings
        case .verifying, .ready:
            return .none
        }
    }

    public static func fallbackActions(for health: PermissionHealth) -> [PermissionSetupAction] {
        guard health == .needsAccessibility else { return [] }
        return [.openAccessibilitySettings, .revealRunningApp]
    }
}

public struct PermissionHealthPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let actionTitle: String?
    public let showsSetupIndicator: Bool
    public let showsProgress: Bool

    public init(
        title: String,
        detail: String,
        actionTitle: String?,
        showsSetupIndicator: Bool,
        showsProgress: Bool
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.showsSetupIndicator = showsSetupIndicator
        self.showsProgress = showsProgress
    }
}

public enum PermissionHealthPresentationPolicy {
    public static func presentation(
        for health: PermissionHealth,
        appName: String,
        appPath: String
    ) -> PermissionHealthPresentation {
        switch health {
        case .needsAccessibility:
            return PermissionHealthPresentation(
                title: "Enable \(appName) in Accessibility",
                detail: "In System Settings, turn on \(appName). Running app: \(appPath). This enables global shortcuts, terminal targeting, and pill placement.",
                actionTitle: "Enable Accessibility",
                showsSetupIndicator: true,
                showsProgress: false
            )
        case .verifying:
            return PermissionHealthPresentation(
                title: "Verifying \(appName) Accessibility",
                detail: "Checking that \(appName) can control the required macOS features.",
                actionTitle: nil,
                showsSetupIndicator: false,
                showsProgress: true
            )
        case .needsRepair:
            return PermissionHealthPresentation(
                title: "Repair \(appName) Accessibility access",
                detail: "macOS reports permission for \(appName), but the running app could not verify access: \(appPath).",
                actionTitle: "Open Accessibility Settings",
                showsSetupIndicator: true,
                showsProgress: false
            )
        case .ready:
            return PermissionHealthPresentation(
                title: "Accessibility ready",
                detail: "\(appName) can use the required macOS controls.",
                actionTitle: nil,
                showsSetupIndicator: false,
                showsProgress: false
            )
        }
    }
}
