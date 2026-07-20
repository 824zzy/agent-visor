import XCTest
@testable import AgentVisorCore

final class PermissionHealthPolicyTests: XCTestCase {
    func testUntrustedRunningAppNeedsAccessibility() {
        let health = PermissionHealthPolicy.evaluate(
            accessibilityTrusted: false,
            functionalProbe: .notRun
        )

        XCTAssertEqual(health, .needsAccessibility)
    }

    func testUntrustedSetupActionRequestsNativeAccessibilityAccess() {
        XCTAssertEqual(
            PermissionSetupPolicy.primaryAction(for: .needsAccessibility),
            .requestAccessibility
        )
    }

    func testRepairSetupActionOpensAccessibilitySettings() {
        XCTAssertEqual(
            PermissionSetupPolicy.primaryAction(for: .needsRepair),
            .openAccessibilitySettings
        )
    }

    func testHealthyOrVerifyingSetupActionDoesNothing() {
        XCTAssertEqual(PermissionSetupPolicy.primaryAction(for: .verifying), .none)
        XCTAssertEqual(PermissionSetupPolicy.primaryAction(for: .ready), .none)
    }

    func testUntrustedSetupKeepsSettingsAndAppRevealFallbacks() {
        XCTAssertEqual(
            PermissionSetupPolicy.fallbackActions(for: .needsAccessibility),
            [.openAccessibilitySettings, .revealRunningApp]
        )
    }

    func testTrustedRunningAppWithSuccessfulProbeIsReady() {
        let health = PermissionHealthPolicy.evaluate(
            accessibilityTrusted: true,
            functionalProbe: .passed
        )

        XCTAssertEqual(health, .ready)
    }

    func testTrustedRunningAppWithFailedProbeNeedsRepair() {
        let health = PermissionHealthPolicy.evaluate(
            accessibilityTrusted: true,
            functionalProbe: .failed
        )

        XCTAssertEqual(health, .needsRepair)
    }

    func testAccessibilityBlockerPresentationOffersDirectSetup() {
        let presentation = PermissionHealthPresentationPolicy.presentation(
            for: .needsAccessibility,
            appName: "Agent Visor",
            appPath: "/Applications/Agent Visor.app"
        )

        XCTAssertEqual(presentation.title, "Enable Agent Visor in Accessibility")
        XCTAssertEqual(presentation.actionTitle, "Enable Accessibility")
        XCTAssertTrue(presentation.detail.contains("/Applications/Agent Visor.app"))
        XCTAssertTrue(presentation.showsSetupIndicator)
        XCTAssertFalse(presentation.showsProgress)
    }

    func testDevelopmentBuildNamesTheExactAccessibilityRow() {
        let presentation = PermissionHealthPresentationPolicy.presentation(
            for: .needsAccessibility,
            appName: "Agent Visor Dev",
            appPath: "/tmp/av-debug-build/Build/Products/Debug/Agent Visor Dev.app"
        )

        XCTAssertEqual(
            presentation.title,
            "Enable Agent Visor Dev in Accessibility"
        )
        XCTAssertTrue(presentation.detail.contains("Agent Visor Dev"))
        XCTAssertTrue(presentation.detail.contains("Agent Visor Dev.app"))
        XCTAssertFalse(
            presentation.detail.contains("Allow this running copy"),
            "The setup copy must identify the visible System Settings row explicitly."
        )
    }

    func testOnlyFirstTransitionIntoReadyRequiresRecoveryWork() {
        XCTAssertTrue(
            PermissionHealthPolicy.requiresRecoveryWork(
                from: .needsAccessibility,
                to: .ready
            )
        )
        XCTAssertFalse(
            PermissionHealthPolicy.requiresRecoveryWork(
                from: .ready,
                to: .ready
            )
        )
    }
}
