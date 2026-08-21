import XCTest

final class StatusTrayLayoutWiringAuditTests: XCTestCase {
    func testRightSafeWidthUsesStableCoordinatorEvidence() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/PillStripView.swift"))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/MenuBarLayoutCoordinator.swift"))

        XCTAssertTrue(pillStrip.contains("menuLayoutCoordinator.statusTraySafeWidth("))
        XCTAssertFalse(pillStrip.contains("findStatusBarLeftEdge"))
        XCTAssertTrue(coordinator.contains("StatusTrayLayoutPolicy.applying("))
        XCTAssertTrue(coordinator.contains("observedAt: Foundation.ProcessInfo.processInfo.systemUptime"))
        XCTAssertTrue(coordinator.contains("StatusTrayLayoutPolicy.safeWidth("))
        XCTAssertTrue(coordinator.contains("updateStatusTrayEdge(screenRect: screenRect)"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
