import XCTest

final class NotchMenuLayoutWiringAuditTests: XCTestCase {
    func testNotchWidthUsesOneOwnerBoundCoordinatorSnapshot() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let notchView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/NotchView.swift"))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/NotchMenuLayoutCoordinator.swift"))

        XCTAssertTrue(notchView.contains("@StateObject private var menuLayoutCoordinator"))
        XCTAssertTrue(notchView.contains("menuLayoutCoordinator.safeWidth"))
        XCTAssertFalse(notchView.contains("frontmostCached"))
        XCTAssertFalse(notchView.contains("probeIsOnTarget"))

        XCTAssertTrue(coordinator.contains("NotchMenuLayoutPolicy.begin"))
        XCTAssertTrue(coordinator.contains("NotchMenuLayoutPolicy.applying"))
        XCTAssertTrue(coordinator.contains("ownerBundleID"))
        XCTAssertTrue(coordinator.contains("requestID"))
        XCTAssertTrue(coordinator.contains("localOwnerEdge: localOwnerEdge"))
        XCTAssertTrue(coordinator.contains("newContext.ownerPid == getpid()"))
        XCTAssertTrue(coordinator.contains("localMenuBarRightEdge"))
        XCTAssertTrue(coordinator.contains("LocalMenuBarEdgeEstimator.estimate"))
        XCTAssertTrue(coordinator.contains("case localOwner"))
        XCTAssertTrue(coordinator.contains(".localOwner(edge: edge"))
    }

    func testPeriodicProbeDoesNotResolveOwnerAgainForWindowMovement() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/NotchMenuLayoutCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("let frontmostPid: pid_t?"))
        XCTAssertTrue(coordinator.contains("NotchMenuContextRefreshPolicy.shouldResolveOwner"))
        XCTAssertTrue(coordinator.contains("contextFrontmostPid: context?.frontmostPid"))
        XCTAssertTrue(coordinator.contains("observedFrontmostPid: observedFrontmostPid"))
        XCTAssertTrue(coordinator.contains("contextTargetScreenID: context?.targetScreenID"))
        XCTAssertTrue(coordinator.contains("observedTargetScreenID: observedTargetScreenID"))
        XCTAssertTrue(coordinator.contains("contextOwnerIsResolved: context?.ownerIsResolved ?? false"))
    }

    func testTopmostMenuOwnerSkipsHelpersThatCannotOwnAnAppMenu() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/NotchMenuLayoutCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("NotchMenuOwnerCandidatePolicy.canOwnTargetMenu"))
        XCTAssertTrue(coordinator.contains("isRegularApplication: app?.activationPolicy == .regular"))
        XCTAssertTrue(coordinator.contains("hasBundleIdentifier: !(app?.bundleIdentifier?.isEmpty ?? true)"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
