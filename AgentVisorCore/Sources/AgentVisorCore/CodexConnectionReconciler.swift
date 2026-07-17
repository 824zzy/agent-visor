public enum CodexConnectionLifecycle: Equatable, Sendable {
    case off
    case preparing
    case requiresBackgroundApproval
    case waitingForNextCodexLaunch
    case connected
    case reconnecting
    case disconnectPending
    case failedObserved(message: String)
}

public enum CodexSharedRuntimeServiceState: Equatable, Sendable {
    case notRegistered
    case requiresBackgroundApproval
    case healthy
    case unhealthy(message: String)
}

public enum CodexConnectionAction: Equatable, Sendable {
    case registerSharedRuntime
    case armFutureDesktopLaunches
    case disarmFutureDesktopLaunches
    case unregisterSharedRuntime
}

public struct CodexConnectionSnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let lifecycle: CodexConnectionLifecycle
    public let serviceState: CodexSharedRuntimeServiceState
    public let desktopRuntime: CodexDesktopRuntime
    public let futureLaunchesArmed: Bool
    public let futureLaunchesOwned: Bool
    public let agentVisorClientConnected: Bool

    public init(
        isEnabled: Bool,
        lifecycle: CodexConnectionLifecycle,
        serviceState: CodexSharedRuntimeServiceState,
        desktopRuntime: CodexDesktopRuntime,
        futureLaunchesArmed: Bool,
        futureLaunchesOwned: Bool,
        agentVisorClientConnected: Bool
    ) {
        self.isEnabled = isEnabled
        self.lifecycle = lifecycle
        self.serviceState = serviceState
        self.desktopRuntime = desktopRuntime
        self.futureLaunchesArmed = futureLaunchesArmed
        self.futureLaunchesOwned = futureLaunchesOwned
        self.agentVisorClientConnected = agentVisorClientConnected
    }
}

public struct CodexConnectionReconciliation: Equatable, Sendable {
    public let lifecycle: CodexConnectionLifecycle
    public let actions: [CodexConnectionAction]

    public init(
        lifecycle: CodexConnectionLifecycle,
        actions: [CodexConnectionAction]
    ) {
        self.lifecycle = lifecycle
        self.actions = actions
    }
}

public enum CodexConnectionReconciler {
    public static func reconcile(
        _ snapshot: CodexConnectionSnapshot
    ) -> CodexConnectionReconciliation {
        if !snapshot.isEnabled {
            var actions: [CodexConnectionAction] = []
            let mustDisarmOwnedLaunches = snapshot.futureLaunchesArmed
                && snapshot.futureLaunchesOwned
            if mustDisarmOwnedLaunches {
                actions.append(.disarmFutureDesktopLaunches)
            }
            if !mustDisarmOwnedLaunches,
               (snapshot.desktopRuntime == .notRunning
                || snapshot.desktopRuntime == .privateRuntime),
               snapshot.serviceState != .notRegistered {
                actions.append(.unregisterSharedRuntime)
            }
            return CodexConnectionReconciliation(
                lifecycle: snapshot.desktopRuntime == .notRunning
                    || snapshot.desktopRuntime == .privateRuntime
                    ? .off
                    : .disconnectPending,
                actions: actions
            )
        }

        switch snapshot.serviceState {
        case .notRegistered:
            return CodexConnectionReconciliation(
                lifecycle: .preparing,
                actions: [.registerSharedRuntime]
            )
        case .requiresBackgroundApproval:
            return CodexConnectionReconciliation(
                lifecycle: .requiresBackgroundApproval,
                actions: snapshot.futureLaunchesArmed && snapshot.futureLaunchesOwned
                    ? [.disarmFutureDesktopLaunches]
                    : []
            )
        case .unhealthy(let message):
            return CodexConnectionReconciliation(
                lifecycle: .failedObserved(message: message),
                actions: snapshot.futureLaunchesArmed && snapshot.futureLaunchesOwned
                    ? [.disarmFutureDesktopLaunches]
                    : []
            )
        case .healthy:
            if snapshot.desktopRuntime == .starting,
               snapshot.lifecycle == .connected || snapshot.lifecycle == .reconnecting {
                return CodexConnectionReconciliation(
                    lifecycle: .reconnecting,
                    actions: snapshot.futureLaunchesArmed ? [] : [.armFutureDesktopLaunches]
                )
            }
            if snapshot.desktopRuntime == .sharedRuntime,
               snapshot.agentVisorClientConnected {
                return CodexConnectionReconciliation(
                    lifecycle: .connected,
                    actions: snapshot.futureLaunchesArmed ? [] : [.armFutureDesktopLaunches]
                )
            }
            return CodexConnectionReconciliation(
                lifecycle: .waitingForNextCodexLaunch,
                actions: snapshot.futureLaunchesArmed ? [] : [.armFutureDesktopLaunches]
            )
        }
    }
}

public enum CodexConnectionObservationPolicy {
    public static func shouldObserve(
        isEnabled: Bool,
        lifecycle: CodexConnectionLifecycle
    ) -> Bool {
        isEnabled || lifecycle == .disconnectPending
    }
}
