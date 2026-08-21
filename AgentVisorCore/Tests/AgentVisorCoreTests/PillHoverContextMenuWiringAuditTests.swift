import XCTest

final class PillHoverContextMenuWiringAuditTests: XCTestCase {
    func testSessionContextMenuOwnsHoverDismissalAndSuppression() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/PillHoverContextMenuCoordinator.swift"
        ))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/PillStripContent.swift"
        ))
        let pillStrip = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/PillStripView.swift"
        ))

        XCTAssertTrue(coordinator.contains("PillHoverContextMenuPolicy.applying"))
        XCTAssertTrue(sideContent.contains("hoverContextMenuCoordinator.pointerEntered"))
        XCTAssertTrue(sideContent.contains("hoverContextMenuCoordinator.pointerExited"))
        XCTAssertTrue(sideContent.contains("hoverContextMenuCoordinator.canPresentHover"))
        XCTAssertTrue(sideContent.contains("hoverContextMenuCoordinator.dismissalRevision"))
        XCTAssertTrue(pillStrip.contains("hoverContextMenuCoordinator.contextMenuOpened"))
        XCTAssertTrue(pillStrip.contains("hoverContextMenuCoordinator.contextMenuClosed"))
        XCTAssertTrue(pillStrip.contains("hoverContextMenuCoordinator.primaryActionTriggered"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
