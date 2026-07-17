import XCTest

final class FullScreenPillVisibilityWiringAuditTests: XCTestCase {
    func testSettingsUseTheCorePolicyAndMigrateLegacyValues() throws {
        let root = repoRoot()
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Core/Settings.swift"))

        XCTAssertTrue(settings.contains("typealias FullScreenPolicy = FullScreenPillPolicy"))
        XCTAssertTrue(settings.contains("FullScreenPillPolicy.fromPersistedValue"))
        XCTAssertFalse(settings.contains("case media = \"media\""))
        XCTAssertFalse(settings.contains("case never = \"never\""))
    }

    func testNotchViewRendersCurrentLayoutWhileVisibilityPolicyControlsOpacityAndClicks() throws {
        let root = repoRoot()
        let notchView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/NotchView.swift"))

        XCTAssertTrue(notchView.contains("FullScreenPillVisibilityPolicy.isVisible"))
        XCTAssertTrue(notchView.contains("if hasPillContent"))
        XCTAssertTrue(notchView.contains(".opacity(pillsAreVisible ? 1 : 0)"))
        XCTAssertTrue(notchView.contains("guard pillsAreVisible else"))
        XCTAssertTrue(notchView.contains("GlobalSessionShortcutManager.shared"))
    }

    func testNotchViewUsesTargetScreenPointerZonesAndDelayedPeekState() throws {
        let root = repoRoot()
        let notchView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/NotchView.swift"))

        XCTAssertTrue(notchView.contains("EventMonitor(mask: .mouseMoved"))
        XCTAssertTrue(notchView.contains("FullScreenPillPointerZonePolicy.contains"))
        XCTAssertTrue(notchView.contains("startFullScreenPointerMonitor"))
        XCTAssertTrue(notchView.contains("scheduleFullScreenPointerHide"))
        XCTAssertTrue(notchView.contains("scheduleFullScreenShortcutHide"))
    }

    func testMediaSleepInferenceIsNoLongerPartOfFullScreenVisibility() throws {
        let root = repoRoot()
        let viewModel = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Core/NotchViewModel.swift"))

        XCTAssertFalse(viewModel.contains("DisplaySleepAssertions"))
        XCTAssertFalse(viewModel.contains("pillsShouldHide"))
    }

    func testSettingsExplainEachFullScreenChoice() throws {
        let root = repoRoot()
        let picker = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/FullScreenPolicyPickerRow.swift"))

        XCTAssertTrue(picker.contains("policy.displayDetail"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
