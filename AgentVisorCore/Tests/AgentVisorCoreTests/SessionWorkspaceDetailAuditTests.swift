import XCTest

final class SessionWorkspaceDetailAuditTests: XCTestCase {
    func testMainWindowDefaultsToSessionBriefAndKeepsTranscriptExplicit() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let splitSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let detailSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        XCTAssertTrue(splitSource.contains("SessionWorkspaceDetail(sessionId: id)"))
        XCTAssertFalse(splitSource.contains("ChatViewHost(sessionId: id)"))
        XCTAssertTrue(detailSource.contains("@State private var mode: SessionWorkspaceMode = .brief"))
        XCTAssertTrue(detailSource.contains("SessionBriefView(session: session"))
        XCTAssertTrue(detailSource.contains("ChatViewHost(sessionId: session.sessionId)"))
        XCTAssertTrue(detailSource.contains("SessionNavigator.navigateToSession(session)"))
    }

    func testInspectorUsesQuietSurfacesAndTighterTopSpacing() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        XCTAssertTrue(source.contains("private enum SessionInspectorTheme"))
        XCTAssertTrue(source.contains(".padding(.horizontal, 28)"))
        XCTAssertTrue(source.contains(".padding(.top, 18)"))
        XCTAssertTrue(source.contains(".fill(SessionInspectorTheme.card)"))
        XCTAssertFalse(source.contains(".padding(32)"))
        XCTAssertFalse(source.contains(".fill(ChatTheme.cardBg)"))
    }

    func testInspectorRendersExcerptsAndDoesNotStyleSecondaryActionAsDisabled() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))
        let sidebar = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/WindowSidebarRow.swift"))

        XCTAssertTrue(source.contains("attributedExcerpt(latestActivityText)"))
        XCTAssertTrue(source.contains("SessionActivityExcerptFormatter.attributedText(source)"))
        XCTAssertTrue(sidebar.contains("SessionActivityExcerptFormatter.singleLine"))
        XCTAssertTrue(source.contains("Text(attributedExcerpt(first))"))
        XCTAssertFalse(source.contains("Text(latestActivityText)"))
        XCTAssertTrue(source.contains(".fill(prominent ? tint : Color.clear)"))
        XCTAssertFalse(source.contains("LATEST ACTIVITY"))
        XCTAssertFalse(source.contains("SESSION CONTEXT"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
