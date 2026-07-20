import XCTest

final class PermissionHealthWiringAuditTests: XCTestCase {
    func testAppDelegateStartsPermissionHealthWithoutResettingTCC() throws {
        let appDelegate = try source("AgentVisor/App/AppDelegate.swift")

        XCTAssertTrue(appDelegate.contains("PermissionHealthMonitor.shared.start()"))
        XCTAssertFalse(appDelegate.contains("tccutil"))
        XCTAssertFalse(appDelegate.contains("[\"reset\", service, bundleID]"))
    }

    func testAccessibilityRecoveryRearmsHotkeysAndReprobesMenuLayout() throws {
        let appDelegate = try source("AgentVisor/App/AppDelegate.swift")
        let hotkeyManager = try source("AgentVisor/Events/HotkeyManager.swift")
        let notchView = try source("AgentVisor/UI/Views/NotchView.swift")

        XCTAssertTrue(appDelegate.contains("PermissionHealthMonitor.shared.onReadyTransition"))
        XCTAssertTrue(appDelegate.contains("HotkeyManager.shared.rearmAfterAccessibilityRecovery()"))
        XCTAssertTrue(hotkeyManager.contains("func rearmAfterAccessibilityRecovery()"))
        XCTAssertTrue(notchView.contains("publisher(for: .agentVisorAccessibilityRecovered)"))
        XCTAssertTrue(notchView.contains("menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)"))
    }

    func testMainWindowAndSettingsRenderTheSharedPermissionHealth() throws {
        let mainSplitView = try source("AgentVisor/UI/Window/MainSplitView.swift")
        let settingsView = try source("AgentVisor/UI/Window/SettingsWindowView.swift")

        XCTAssertTrue(mainSplitView.contains("@ObservedObject private var permissionHealth = PermissionHealthMonitor.shared"))
        XCTAssertTrue(mainSplitView.contains("permissionHealthBanner"))
        XCTAssertTrue(mainSplitView.contains("if permissionHealth.health != .ready"))
        XCTAssertTrue(settingsView.contains("@ObservedObject private var permissionHealth = PermissionHealthMonitor.shared"))
        XCTAssertTrue(settingsView.contains("permissionHealth.presentation"))
        XCTAssertFalse(settingsView.contains("@State private var axTrusted"))
    }

    func testNativeStatusItemShowsSetupOnlyWhilePermissionIsBlocked() throws {
        let controller = try source(
            "AgentVisor/UI/Window/PillAccessibilityStatusItemController.swift"
        )

        XCTAssertTrue(controller.contains("PermissionHealthMonitor.shared.$health"))
        XCTAssertTrue(controller.contains("presentation.showsSetupIndicator"))
        XCTAssertTrue(controller.contains("button.title = \"Setup\""))
        XCTAssertTrue(controller.contains("#selector(performSetup)"))
        XCTAssertTrue(controller.contains("performPrimarySetupAction()"))
        XCTAssertTrue(controller.contains("NSWorkspace.shared.isVoiceOverEnabled"))
    }

    func testExplicitSetupRequestsNativePromptWithoutPersistedSuppression() throws {
        let monitor = try source(
            "AgentVisor/Services/Permissions/PermissionHealthMonitor.swift"
        )

        XCTAssertTrue(monitor.contains("func performPrimarySetupAction()"))
        XCTAssertTrue(monitor.contains("AXIsProcessTrustedWithOptions(options)"))
        XCTAssertTrue(monitor.contains("kAXTrustedCheckOptionPrompt.takeUnretainedValue()"))
        XCTAssertFalse(monitor.contains("nativePromptDefaultsKey"))
        XCTAssertFalse(monitor.contains("refresh(promptIfNeeded:"))
    }

    func testMainWindowAndSettingsUseTheSameExplicitSetupAction() throws {
        let mainSplitView = try source("AgentVisor/UI/Window/MainSplitView.swift")
        let settingsView = try source("AgentVisor/UI/Window/SettingsWindowView.swift")

        XCTAssertTrue(mainSplitView.contains("permissionHealth.performPrimarySetupAction()"))
        XCTAssertTrue(settingsView.contains("permissionHealth.performPrimarySetupAction()"))
    }

    func testUntrustedSetupOffersSettingsAndRunningAppFallbacks() throws {
        let monitor = try source(
            "AgentVisor/Services/Permissions/PermissionHealthMonitor.swift"
        )
        let mainSplitView = try source("AgentVisor/UI/Window/MainSplitView.swift")
        let settingsView = try source("AgentVisor/UI/Window/SettingsWindowView.swift")

        XCTAssertTrue(monitor.contains("func revealRunningApp()"))
        XCTAssertTrue(monitor.contains("activateFileViewerSelecting([Bundle.main.bundleURL])"))
        for source in [mainSplitView, settingsView] {
            XCTAssertTrue(source.contains("\"Open Settings\""))
            XCTAssertTrue(source.contains("permissionHealth.openAccessibilitySettings()"))
            XCTAssertTrue(source.contains("\"Reveal App\""))
            XCTAssertTrue(source.contains("permissionHealth.revealRunningApp()"))
        }
    }

    func testPermissionPresentationUsesTheRunningBuildDisplayName() throws {
        let monitor = try source(
            "AgentVisor/Services/Permissions/PermissionHealthMonitor.swift"
        )

        XCTAssertTrue(monitor.contains("appName: runningAppName"))
        XCTAssertTrue(monitor.contains("CFBundleDisplayName"))
        XCTAssertFalse(
            monitor.contains("appName: AppBranding.appName"),
            "Debug permission copy must not call itself by the release name."
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
