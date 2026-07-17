import XCTest

final class SessionNavigatorKeyboardWiringAuditTests: XCTestCase {
    func testOverflowPopoverOwnsAndConsumesKeyboardNavigation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("NotchSideContent.swift"))
        let notchView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift"))

        XCTAssertTrue(sideContent.contains("SessionNavigatorKeyboardEventMonitor"))
        XCTAssertTrue(sideContent.contains("CGEvent.tapCreate("))
        XCTAssertTrue(sideContent.contains("options: .defaultTap"))
        XCTAssertTrue(sideContent.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(sideContent.contains("SessionNavigatorKeyboardInputPolicy.event"))
        XCTAssertTrue(sideContent.contains("text: text"))
        XCTAssertFalse(sideContent.contains("window.makeKey()"))
        XCTAssertTrue(sideContent.contains("keyboardMonitor.start()"))
        XCTAssertTrue(sideContent.contains("keyboardMonitor.stop()"))
        XCTAssertTrue(sideContent.contains("SessionNavigatorKeyboardPolicy.reduce"))
        XCTAssertTrue(sideContent.contains("query: searchQuery"))
        XCTAssertTrue(sideContent.contains("searchQuery = decision.query"))
        XCTAssertTrue(sideContent.contains("isKeyboardSelected:"))
        XCTAssertFalse(sideContent.contains("super.keyDown(with: event)"))
        XCTAssertTrue(notchView.contains("onDismiss: {\n                        dismissTransientPopovers()"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
