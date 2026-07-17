import XCTest

final class ShippedDebugInstrumentationAuditTests: XCTestCase {
    func testBundledHookScriptDoesNotDumpPermissionPayloads() throws {
        let source = try String(contentsOf: repoRootURL(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Resources")
            .appendingPathComponent("agent-visor-state.py"))

        XCTAssertFalse(
            source.contains("/tmp/av-permission-debug.log"),
            "The bundled hook script must not ship PermissionRequest payload dumps."
        )
        XCTAssertFalse(
            source.contains("TEMP debug"),
            "The bundled hook script must not contain temporary debug blocks."
        )
    }

    func testTerminalAdaptersDoNotLogPromptPreviews() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let iTermSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("ITermAdapter.swift"))
        let ghosttySource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Navigation")
            .appendingPathComponent("GhosttyScripting.swift"))

        for source in [iTermSource, ghosttySource] {
            XCTAssertFalse(
                source.contains("PROBE 2026-05-26"),
                "Old send-path probes should not ship in terminal adapters."
            )
            XCTAssertFalse(
                source.contains("preview=["),
                "Terminal send-path logs must not include prompt previews."
            )
        }
    }

    func testPillRenderDiagnosticsOnlyLogSnapshotChanges() throws {
        let source = try String(contentsOf: repoRootURL(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift"))

        XCTAssertTrue(source.contains("if previousSnapshot != renderedSnapshot"))
        XCTAssertFalse(source.contains("pillRaceLog.notice(\"render mode=") &&
            !source.contains("previousSnapshot"))
    }

    private func repoRootURL(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
