import XCTest

final class SettingsCopyAuditTests: XCTestCase {
    func testSettingsDescribeCurrentWindowPillAndCodexBehavior() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift"))

        XCTAssertTrue(source.contains("Show or hide the Agent Visor main window"))
        XCTAssertTrue(source.contains("Menu-bar shortcuts for active and recent sessions"))
        XCTAssertTrue(source.contains("Connected Codex sessions can also be controlled from Agent Visor"))
        XCTAssertTrue(source.contains("status tracking and the +N recent-session browser"))
        XCTAssertTrue(source.contains("Sessions window can still search saved Codex history"))
        XCTAssertFalse(source.contains("toggles the notch panel"))
        XCTAssertFalse(source.contains("pills still show active status only"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
