import Foundation
import XCTest

final class PiRebootRestorationWiringAuditTests: XCTestCase {
    func testAppLifecycleStartsAndFreezesTheRestorationCoordinator() throws {
        let root = repoRoot()
        let appDelegate = try String(contentsOf: root.appendingPathComponent("AgentVisor/App/AppDelegate.swift"))

        XCTAssertTrue(appDelegate.contains("NSWorkspace.willPowerOffNotification"))
        XCTAssertTrue(appDelegate.contains("PiRebootRestorationManager.shared.start"))
        XCTAssertTrue(appDelegate.contains("PiRebootRestorationManager.shared.freezeForSystemPowerOff"))
        XCTAssertTrue(appDelegate.contains("PiRebootRestorationManager.shared.invalidateForCleanAppTermination"))
    }

    func testAcceptedPiLifecycleFeedsTheRestorationCoordinator() throws {
        let root = repoRoot()
        let store = try String(contentsOf: root.appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))
        let hook = try String(contentsOf: root.appendingPathComponent("AgentVisor/Services/Hooks/HookSocketServer.swift"))

        XCTAssertTrue(hook.contains("let sessionFile: String?"))
        XCTAssertTrue(hook.contains("case sessionFile = \"session_file\""))
        XCTAssertTrue(store.contains("PiRebootRestorationManager.shared.recordAcceptedSession"))
        XCTAssertTrue(store.contains("PiRebootRestorationManager.shared.end"))
        XCTAssertTrue(store.contains("runtimeOwnershipDisposition == .ignoreCompetingRuntime"))
    }

    func testHostManagerClaimsBeforeRunningGhosttyAutomation() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))

        guard let claim = manager.range(of: "claimRestorePlan")?.lowerBound,
              let save = manager.range(of: "try snapshotStore.save", range: claim..<manager.endIndex)?.lowerBound,
              let automate = manager.range(of: "PiGhosttyRestorationScript.make", range: save..<manager.endIndex)?.lowerBound else {
            return XCTFail("Expected claim → durable save → Ghostty automation ordering")
        }
        XCTAssertLessThan(claim, save)
        XCTAssertLessThan(save, automate)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
