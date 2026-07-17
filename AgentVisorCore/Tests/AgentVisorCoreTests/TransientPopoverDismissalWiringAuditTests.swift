import XCTest

final class TransientPopoverDismissalWiringAuditTests: XCTestCase {
    func testPopoverContentRegistersItsWindowForInsideClickDetection() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))
        let notchView = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/NotchView.swift"
        ))

        XCTAssertTrue(sideContent.contains("struct PopoverWindowReader: NSViewRepresentable"))
        XCTAssertTrue(sideContent.contains("onWindowChange"))
        XCTAssertTrue(notchView.contains("transientPopoverWindowTracker"))
    }

    func testGlobalInputMonitorAppliesTransientDismissalPolicy() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let notchView = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/NotchView.swift"
        ))

        XCTAssertTrue(
            notchView.contains("EventMonitor(mask: .keyDown)")
        )
        XCTAssertTrue(notchView.contains("startTransientPopoverKeyMonitor()"))
        XCTAssertTrue(
            notchView.contains(
                "transientPopoverWindowTracker.contains(\n            eventWindow: event.window,\n            screenPoint: NSEvent.mouseLocation"
            ),
            "Global events have no app window, so inside-popover detection must also use the popover's screen frame."
        )
        XCTAssertTrue(notchView.contains("applyTransientPopoverPolicy(.outsideClick)"))
        XCTAssertTrue(notchView.contains(".escapeKey : .otherKey"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
