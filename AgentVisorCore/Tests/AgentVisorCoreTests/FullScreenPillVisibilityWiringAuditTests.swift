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

    func testPillStripViewRendersCurrentLayoutWhileVisibilityPolicyControlsOpacityAndClicks() throws {
        let root = repoRoot()
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/PillStripView.swift"))

        XCTAssertTrue(pillStrip.contains("FullScreenPillVisibilityPolicy.isVisible"))
        XCTAssertTrue(pillStrip.contains("if hasPillContent"))
        XCTAssertTrue(pillStrip.contains(".opacity(pillsAreVisible ? 1 : 0)"))
        XCTAssertTrue(pillStrip.contains("guard pillsAreVisible else"))
        XCTAssertTrue(pillStrip.contains("GlobalSessionShortcutManager.shared"))
    }

    func testPillStripViewUsesTargetScreenPointerZonesAndDelayedPeekState() throws {
        let root = repoRoot()
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/PillStripView.swift"))

        XCTAssertTrue(pillStrip.contains("EventMonitor(mask: .mouseMoved"))
        XCTAssertTrue(pillStrip.contains("FullScreenPillPointerZonePolicy.contains"))
        XCTAssertTrue(pillStrip.contains("startFullScreenPointerMonitor"))
        XCTAssertTrue(pillStrip.contains("scheduleFullScreenPointerHide"))
        XCTAssertTrue(pillStrip.contains("scheduleFullScreenShortcutHide"))
    }

    func testMediaSleepInferenceIsNoLongerPartOfFullScreenVisibility() throws {
        let root = repoRoot()
        let viewModel = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Core/PillStripViewModel.swift"))

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
