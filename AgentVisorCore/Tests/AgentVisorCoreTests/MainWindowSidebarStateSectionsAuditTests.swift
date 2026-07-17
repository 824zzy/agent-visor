import XCTest

final class MainWindowSidebarStateSectionsAuditTests: XCTestCase {
    func testSessionsBrowserBuildsStateSectionsNotProjectGroups() throws {
        let source = try String(contentsOf: mainWindowViewModelURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("SessionBrowserPolicy.select"),
            "The full window should use the shared Sessions browser policy."
        )
        XCTAssertFalse(
            source.contains("SessionBrowserSection.project"),
            "Project context should remain row metadata, not a top-level section."
        )
    }

    func testSessionsBrowserHasNoProjectDragOrdering() throws {
        let source = try String(contentsOf: mainSplitViewURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(source.contains("viewModel.browserListElements"))
        XCTAssertFalse(source.contains("viewModel.browserSelection.groups"))
        XCTAssertFalse(source.contains(".draggable("))
        XCTAssertFalse(source.contains(".dropDestination("))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func mainWindowViewModelURL(from testFile: URL) -> URL {
        repoRoot(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainWindowViewModel.swift")
    }

    private func mainSplitViewURL(from testFile: URL) -> URL {
        repoRoot(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainSplitView.swift")
    }
}
