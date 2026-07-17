import XCTest

final class SessionPhasePriorityAuditTests: XCTestCase {
    func testSessionPhaseCentralizesDisplayPriorityWithApprovalAboveProcessing() throws {
        let source = try String(contentsOf: sessionPhaseURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("var displayPriority: Int"),
            "SessionPhase should own the compact pill display priority."
        )
        XCTAssertTrue(
            source.contains("case .waitingForApproval: return 0"),
            "Pending approval must be the highest display priority so it cannot be crowded out by processing sessions."
        )
        XCTAssertTrue(
            source.contains("case .processing, .compacting: return 1"),
            "Ordinary active work should be below approval prompts."
        )
    }

    func testWindowUsesStateSectionsAndPillsUseDisplayPriority() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let mainWindow = try String(contentsOf: mainWindowViewModelURL(from: testFile))
        let notchSideContent = try String(contentsOf: notchSideContentURL(from: testFile))

        XCTAssertTrue(
            mainWindow.contains("SidebarStateSectionPolicy.group"),
            "Window sidebar ordering should be state-section first, then recency within each section."
        )
        XCTAssertFalse(
            mainWindow.contains("return phase.displayPriority"),
            "Window sidebar should not use pill display priority as its primary ordering model."
        )
        XCTAssertTrue(
            notchSideContent.contains("return phase.displayPriority"),
            "Pill ordering must delegate to SessionPhase.displayPriority."
        )
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sessionPhaseURL(from testFile: URL) -> URL {
        repoRoot(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionPhase.swift")
    }

    private func mainWindowViewModelURL(from testFile: URL) -> URL {
        repoRoot(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainWindowViewModel.swift")
    }

    private func notchSideContentURL(from testFile: URL) -> URL {
        repoRoot(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("NotchSideContent.swift")
    }
}
