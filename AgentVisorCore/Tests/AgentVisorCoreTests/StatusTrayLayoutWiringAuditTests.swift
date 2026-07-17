import XCTest

final class StatusTrayLayoutWiringAuditTests: XCTestCase {
    func testRightSafeWidthUsesStableCoordinatorEvidence() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let notchView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/NotchView.swift"))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/NotchMenuLayoutCoordinator.swift"))

        XCTAssertTrue(notchView.contains("menuLayoutCoordinator.statusTraySafeWidth("))
        XCTAssertFalse(notchView.contains("findStatusBarLeftEdge"))
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
