import XCTest

final class MenuBarLayoutWiringAuditTests: XCTestCase {
    func testPillStripWidthUsesOneOwnerBoundCoordinatorSnapshot() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/PillStripView.swift"))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/MenuBarLayoutCoordinator.swift"))

        XCTAssertTrue(pillStrip.contains("@StateObject private var menuLayoutCoordinator"))
        XCTAssertTrue(pillStrip.contains("menuLayoutCoordinator.safeWidth"))
        XCTAssertFalse(pillStrip.contains("frontmostCached"))
        XCTAssertFalse(pillStrip.contains("probeIsOnTarget"))

        XCTAssertTrue(coordinator.contains("MenuBarLayoutPolicy.begin"))
        XCTAssertTrue(coordinator.contains("MenuBarLayoutPolicy.applying"))
        XCTAssertTrue(coordinator.contains("ownerBundleID"))
        XCTAssertTrue(coordinator.contains("requestID"))
        XCTAssertTrue(coordinator.contains("localOwnerEdge: localOwnerEdge"))
        XCTAssertTrue(coordinator.contains("newContext.ownerPid == getpid()"))
        XCTAssertTrue(coordinator.contains("localMenuBarRightEdge"))
        XCTAssertTrue(coordinator.contains("LocalMenuBarEdgeEstimator.estimate"))
        XCTAssertTrue(coordinator.contains("case localOwner"))
        XCTAssertTrue(coordinator.contains(".localOwner(edge: edge"))
    }

    func testPeriodicProbeReevaluatesOwnerWhenWindowTopologyChanges() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/MenuBarLayoutCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("let frontmostPid: pid_t?"))
        XCTAssertTrue(coordinator.contains("let observedContext = resolveContext"))
        XCTAssertTrue(coordinator.contains("MenuBarContextRefreshPolicy.shouldResolveOwner"))
        XCTAssertTrue(coordinator.contains("contextFrontmostPid: context?.frontmostPid"))
        XCTAssertTrue(coordinator.contains("observedFrontmostPid: observedFrontmostPid"))
        XCTAssertTrue(coordinator.contains("contextTargetScreenID: context?.targetScreenID"))
        XCTAssertTrue(coordinator.contains("observedTargetScreenID: observedTargetScreenID"))
        XCTAssertTrue(coordinator.contains("contextOwnerPid: context?.ownerPid"))
        XCTAssertTrue(coordinator.contains("observedOwnerPid: observedContext.ownerPid"))
        XCTAssertTrue(coordinator.contains("observedOwnerIsResolved: observedContext.ownerIsResolved"))
        XCTAssertTrue(coordinator.contains("contextOwnerIsResolved: context?.ownerIsResolved ?? false"))
    }

    func testTopmostMenuOwnerSkipsHelpersThatCannotOwnAnAppMenu() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/MenuBar/MenuBarLayoutCoordinator.swift"))

        XCTAssertTrue(coordinator.contains("MenuBarOwnerCandidatePolicy.canOwnTargetMenu"))
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
