import XCTest

final class PendingActionPresentationWiringAuditTests: XCTestCase {
    func testPendingActionSurfacesUseSemanticFallbackPolicy() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let event = try source(root, "AgentVisor/Models/SessionEvent.swift")
        let hook = try source(root, "AgentVisor/Services/Hooks/HookSocketServer.swift")
        let pills = try source(root, "AgentVisor/UI/Components/NotchSideContent.swift")
        let sidebar = try source(root, "AgentVisor/UI/Window/WindowSidebarRow.swift")
        let detail = try source(root, "AgentVisor/UI/Window/SessionWorkspaceDetail.swift")

        XCTAssertTrue(event.contains("PendingActionPresentation.storedToolName"))
        XCTAssertTrue(hook.contains("PendingActionPresentation.storedToolName"))
        XCTAssertTrue(pills.contains("PendingActionPresentation.contextualToolName"))
        XCTAssertTrue(sidebar.contains("PendingActionPresentation.contextualToolName"))
        XCTAssertTrue(detail.contains("PendingActionPresentation.contextualToolName"))
        XCTAssertFalse([event, hook, pills, sidebar, detail].contains { $0.contains("tool ?? \"unknown\"") })
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
