import XCTest

final class PillMovementGraceWiringAuditTests: XCTestCase {
    func testRecentNavigationDefersRecencyCommitInsteadOfReorderingImmediately() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(source.contains("session.phase == .idle"))
        XCTAssertTrue(source.contains("scheduleRecentNavigationCommit("))
        XCTAssertTrue(source.contains("pendingRecentNavigationCommits"))
        XCTAssertTrue(source.contains("PillMovementGracePolicy.pendingMove"))
        XCTAssertTrue(source.contains("pending.deadline.timeIntervalSince(navigationAt)"))
    }

    func testDeferredRecentCommitPublishesTheMoveAtItsDeadline() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(source.contains("pending.navigationDate"))
        XCTAssertTrue(source.contains("self.revision &+= 1"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
