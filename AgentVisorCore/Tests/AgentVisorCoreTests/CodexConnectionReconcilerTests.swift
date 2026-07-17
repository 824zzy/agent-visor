import XCTest
@testable import AgentVisorCore

final class CodexConnectionReconcilerTests: XCTestCase {
    func testEnablingWhileDesktopUsesPrivateRuntimeArmsFutureLaunchWithoutInterruptingDesktop() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .off,
                serviceState: .healthy,
                desktopRuntime: .privateRuntime,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .waitingForNextCodexLaunch)
        XCTAssertEqual(result.actions, [.armFutureDesktopLaunches])
    }

    func testEnablingWithUnregisteredServicePreparesRuntimeBeforeArmingLaunches() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .off,
                serviceState: .notRegistered,
                desktopRuntime: .notRunning,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .preparing)
        XCTAssertEqual(result.actions, [.registerSharedRuntime])
    }

    func testHealthySharedDesktopWithAgentVisorClientConnectedIsConnected() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .preparing,
                serviceState: .healthy,
                desktopRuntime: .sharedRuntime,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: true
            )
        )

        XCTAssertEqual(result.lifecycle, .connected)
        XCTAssertEqual(result.actions, [])
    }

    func testServiceRequiringApprovalDoesNotArmFutureDesktopLaunches() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .preparing,
                serviceState: .requiresBackgroundApproval,
                desktopRuntime: .notRunning,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .requiresBackgroundApproval)
        XCTAssertEqual(result.actions, [])
    }

    func testUnhealthySharedRuntimeFallsBackToObservedWithFailureMessage() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .preparing,
                serviceState: .unhealthy(message: "socket handshake failed"),
                desktopRuntime: .privateRuntime,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(
            result.lifecycle,
            .failedObserved(message: "socket handshake failed")
        )
        XCTAssertEqual(result.actions, [])
    }

    func testUnhealthySharedRuntimeDisarmsFutureDesktopLaunches() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .connected,
                serviceState: .unhealthy(message: "version mismatch"),
                desktopRuntime: .unknown,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(
            result.lifecycle,
            .failedObserved(message: "version mismatch")
        )
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
    }

    func testDisablingConnectedDesktopDisarmsFutureLaunchesButDefersRuntimeUnregister() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .connected,
                serviceState: .healthy,
                desktopRuntime: .sharedRuntime,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: true
            )
        )

        XCTAssertEqual(result.lifecycle, .disconnectPending)
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
        XCTAssertFalse(result.actions.contains(.unregisterSharedRuntime))
    }

    func testDisablingWhileDesktopIsStartingDefersUnregisterUntilDesktopStops() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .preparing,
                serviceState: .healthy,
                desktopRuntime: .starting,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .disconnectPending)
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
        XCTAssertFalse(result.actions.contains(.unregisterSharedRuntime))
    }

    func testDisabledWithDesktopStoppedDisarmsBeforeFreshProbeCanUnregisterRuntime() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .disconnectPending,
                serviceState: .healthy,
                desktopRuntime: .notRunning,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .off)
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
    }

    func testDisabledWithDesktopStoppedUnregistersOnlyAfterLaunchesAreDisarmed() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .disconnectPending,
                serviceState: .healthy,
                desktopRuntime: .notRunning,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .off)
        XCTAssertEqual(result.actions, [.unregisterSharedRuntime])
    }

    func testDisabledWithPrivateDesktopDisarmsBeforeUnregisteringUnusedRuntime() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .waitingForNextCodexLaunch,
                serviceState: .healthy,
                desktopRuntime: .privateRuntime,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: true
            )
        )

        XCTAssertEqual(result.lifecycle, .off)
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
    }

    func testDisabledDoesNotUnsetAFutureLaunchSettingItDoesNotOwn() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .off,
                serviceState: .healthy,
                desktopRuntime: .privateRuntime,
                futureLaunchesArmed: true,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .off)
        XCTAssertEqual(result.actions, [.unregisterSharedRuntime])
    }

    func testDisabledUnknownDesktopRemainsPendingRatherThanAbandoningCleanup() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: false,
                lifecycle: .disconnectPending,
                serviceState: .unhealthy(message: "probe failed"),
                desktopRuntime: .unknown,
                futureLaunchesArmed: false,
                futureLaunchesOwned: false,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .disconnectPending)
        XCTAssertEqual(result.actions, [])
    }

    func testConnectedLifecycleBecomesReconnectingWhileSharedDesktopRestarts() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .connected,
                serviceState: .healthy,
                desktopRuntime: .starting,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .reconnecting)
        XCTAssertEqual(result.actions, [])
    }

    func testApprovalRequirementDisarmsPreviouslyArmedFutureLaunches() {
        let result = CodexConnectionReconciler.reconcile(
            CodexConnectionSnapshot(
                isEnabled: true,
                lifecycle: .preparing,
                serviceState: .requiresBackgroundApproval,
                desktopRuntime: .notRunning,
                futureLaunchesArmed: true,
                futureLaunchesOwned: true,
                agentVisorClientConnected: false
            )
        )

        XCTAssertEqual(result.lifecycle, .requiresBackgroundApproval)
        XCTAssertEqual(result.actions, [.disarmFutureDesktopLaunches])
    }

    func testDisconnectPendingKeepsRuntimeObservationAliveWhileDisabled() {
        XCTAssertTrue(
            CodexConnectionObservationPolicy.shouldObserve(
                isEnabled: false,
                lifecycle: .disconnectPending
            )
        )
        XCTAssertFalse(
            CodexConnectionObservationPolicy.shouldObserve(
                isEnabled: false,
                lifecycle: .off
            )
        )
    }
}
