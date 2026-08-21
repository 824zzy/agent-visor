import XCTest

/// Locks in the shape that fixed "clicking empty space near the top of an
/// external monitor opens the session window".
///
/// The cause was a global mouse-down monitor that asked a captured
/// `NotchGeometry` whether a click was "in the notch". Geometry captured while
/// the built-in display was the main display — `(0, 0, 2056, 1329)` — kept
/// answering yes after that display moved to `(406, -1329, 2056, 1329)`, so in
/// global coordinates its band floated over empty space on the external
/// monitor: an invisible 244x38 click target that summoned the window.
///
/// Two invariants keep it dead:
/// 1. No global pointer monitor turns a click into a window summon. Window
///    summons come from rendered controls (the menu-bar status item, sidebar
///    rows), the Dock, notifications, or the hotkey.
/// 2. The one global click monitor that remains — pill routing — refuses to
///    act on geometry whose display has moved, resized, or gone away.
final class WindowSummonClickAuditTests: XCTestCase {
    func testNoGlobalPointerMonitorDecidesWindowSummons() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AgentVisor/Events/EventMonitors.swift").path
            ),
            "The always-on mouseMoved/leftMouseDown/leftMouseDragged aggregator is retired; nothing should reintroduce it."
        )

        let viewModel = try source(root, "AgentVisor/Core/PillStripViewModel.swift")
        for banned in ["EventMonitors", "handleMouseDown", "handleMouseMove", "isPointInNotch"] {
            XCTAssertFalse(
                viewModel.contains(banned),
                "PillStripViewModel must not resolve global pointer events (\(banned)); it holds captured geometry that outlives display arrangements."
            )
        }
    }

    func testGeometryOwnsNoPointInRegionTests() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let geometry = try source(root, "AgentVisor/Core/NotchGeometry.swift")

        for banned in ["isPointInNotch", "isPointInOpenedPanel", "isPointOutsidePanel"] {
            XCTAssertFalse(
                geometry.contains(banned),
                "NotchGeometry answers rendering questions only. A captured rect must never claim a global point (\(banned))."
            )
        }
    }

    func testPillClickRoutingRejectsStaleDisplayGeometry() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let pillStrip = try source(root, "AgentVisor/UI/Views/PillStripView.swift")
        let viewModel = try source(root, "AgentVisor/Core/PillStripViewModel.swift")

        XCTAssertTrue(
            pillStrip.contains("guard !viewModel.isGeometryStale else {"),
            "handleSideClick must ignore clicks while its captured geometry no longer matches its display."
        )
        XCTAssertTrue(
            viewModel.contains("MenuBarGeometryFreshness.isStale"),
            "Staleness must be decided by the Core policy, not by an ad-hoc frame comparison."
        )
    }

    func testReplacedStripControllerIsTornDownNotJustClosed() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let windowManager = try source(root, "AgentVisor/App/WindowManager.swift")
        let strip = try source(root, "AgentVisor/UI/Window/PillsStripWindow.swift")

        XCTAssertTrue(
            windowManager.contains("existingStrip.teardown()"),
            "A superseded strip must be torn down; closing the window alone left its hosting view, view model and observers alive."
        )
        XCTAssertTrue(
            strip.contains("window?.contentViewController = nil"),
            "Teardown must unmount the SwiftUI view so its onDisappear cleanup runs."
        )
        XCTAssertTrue(
            strip.contains("viewModel.teardown()"),
            "Teardown must drop the view model's subscriptions."
        )
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
