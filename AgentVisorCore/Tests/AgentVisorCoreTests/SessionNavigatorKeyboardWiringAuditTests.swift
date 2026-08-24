import XCTest

final class SessionNavigatorKeyboardWiringAuditTests: XCTestCase {
    func testOverflowPopoverOwnsAndConsumesKeyboardNavigation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("PillStripContent.swift"))
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("PillStripView.swift"))
        let monitor = try String(contentsOf: root
            .appendingPathComponent("AgentVisorCore")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentVisorCore")
            .appendingPathComponent("SessionNavigatorKeyboardEventMonitor.swift"))

        XCTAssertTrue(sideContent.contains("SessionNavigatorKeyboardEventMonitor"))
        XCTAssertTrue(monitor.contains("CGEvent.tapCreate("))
        XCTAssertTrue(monitor.contains("options: .defaultTap"))
        XCTAssertTrue(monitor.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(monitor.contains("SessionNavigatorKeyboardInputPolicy.event"))
        XCTAssertTrue(monitor.contains("text: Self.text"))
        XCTAssertFalse(sideContent.contains("window.makeKey()"))
        XCTAssertTrue(sideContent.contains("keyboardMonitor.start()"))
        XCTAssertTrue(sideContent.contains("keyboardMonitor.stop()"))
        XCTAssertTrue(sideContent.contains("SessionNavigatorKeyboardPolicy.reduce"))
        XCTAssertTrue(sideContent.contains("query: searchQuery"))
        XCTAssertTrue(sideContent.contains("searchQuery = decision.query"))
        XCTAssertTrue(sideContent.contains("isKeyboardSelected:"))
        XCTAssertFalse(sideContent.contains("super.keyDown(with: event)"))
        XCTAssertTrue(pillStrip.contains("onDismiss: {\n                        dismissTransientPopovers()"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
