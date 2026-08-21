import XCTest

final class TransientPopoverDismissalWiringAuditTests: XCTestCase {
    func testPopoverContentRegistersItsWindowForInsideClickDetection() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/PillStripContent.swift"
        ))
        let pillStrip = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/PillStripView.swift"
        ))

        XCTAssertTrue(sideContent.contains("struct PopoverWindowReader: NSViewRepresentable"))
        XCTAssertTrue(sideContent.contains("onWindowChange"))
        XCTAssertTrue(pillStrip.contains("transientPopoverWindowTracker"))
    }

    func testGlobalInputMonitorAppliesTransientDismissalPolicy() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let pillStrip = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/PillStripView.swift"
        ))

        XCTAssertTrue(
            pillStrip.contains("EventMonitor(mask: .keyDown)")
        )
        XCTAssertTrue(pillStrip.contains("startTransientPopoverKeyMonitor()"))
        XCTAssertTrue(
            pillStrip.contains(
                "transientPopoverWindowTracker.contains(\n            eventWindow: event.window,\n            screenPoint: NSEvent.mouseLocation"
            ),
            "Global events have no app window, so inside-popover detection must also use the popover's screen frame."
        )
        XCTAssertTrue(pillStrip.contains("applyTransientPopoverPolicy(.outsideClick)"))
        XCTAssertTrue(pillStrip.contains(".escapeKey : .otherKey"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
