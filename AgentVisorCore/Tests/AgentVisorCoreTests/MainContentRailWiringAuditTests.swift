import XCTest

final class MainContentRailWiringAuditTests: XCTestCase {
    func testSharedSwiftUIRailModifierUsesTheCoreGeometryContract() throws {
        let source = try repositorySource("AgentVisor/UI/Window/MainWindow.swift")

        XCTAssertTrue(source.contains("func mainContentRail("))
        XCTAssertTrue(source.contains("MainContentRailLayout.maximumWidth"))
        XCTAssertTrue(source.contains("MainContentRailLayout.horizontalInset"))
    }

    func testSessionsAndChatHeaderUseTheSameRailModifier() throws {
        let browser = try repositorySource("AgentVisor/UI/Window/MainSplitView.swift")
        let workspace = try repositorySource("AgentVisor/UI/Window/SessionWorkspaceDetail.swift")

        XCTAssertGreaterThanOrEqual(browser.components(separatedBy: ".mainContentRail(").count - 1, 3)
        XCTAssertFalse(browser.contains(".frame(maxWidth: 980"))
        XCTAssertTrue(workspace.contains(".mainContentRail(alignment: .leading)"))
    }

    func testInteractiveChatSurfacesAlignToTheRailWhileCanvasStaysFullBleed() throws {
        let source = try repositorySource("AgentVisor/UI/Window/WindowChatView.swift")
        let body = try sourceSlice(source, from: "var body: some View", to: ".environment(\\.openToolDetail")
        let table = try sourceSlice(source, from: "private var chatTable: some View", to: "private func displayPath")

        XCTAssertTrue(body.contains("ChatTheme.headerBg.ignoresSafeArea()"))
        XCTAssertTrue(body.contains("interactiveSurface(session: session)\n                        .mainContentRail()"))
        XCTAssertTrue(body.contains("ChatStatusBar("))
        XCTAssertGreaterThanOrEqual(body.components(separatedBy: ".mainContentRail()").count - 1, 2)
        XCTAssertTrue(table.contains("ProcessingIndicatorView"))
        XCTAssertTrue(table.contains("LoadEarlierMessagesButton"))
        XCTAssertGreaterThanOrEqual(table.components(separatedBy: ".mainContentRail(").count - 1, 2)
    }

    func testChatContractNamesEveryRailAlignedSurfaceAndFullBleedException() throws {
        let contract = try repositorySource("docs/session-browser-ui.md")

        XCTAssertTrue(contract.contains("Header controls, history rows, work disclosures and expanded tools"))
        XCTAssertTrue(contract.contains("composer or approval controls, and status content align to that rail"))
        XCTAssertTrue(contract.contains("canvas, section backgrounds, dividers, scrolling viewport, and drill-down overlays remain full-bleed"))
    }

    private func repositorySource(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent(path))
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return String(source[startIndex..<endIndex])
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
