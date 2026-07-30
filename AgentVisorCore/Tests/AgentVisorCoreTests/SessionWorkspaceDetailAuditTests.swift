import XCTest

final class SessionWorkspaceDetailAuditTests: XCTestCase {
    func testMainWindowEntersConversationFirstChatInsteadOfATechnicalBrief() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let splitSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let detailSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        XCTAssertTrue(splitSource.contains("SessionChatWorkspace("))
        XCTAssertTrue(detailSource.contains("struct SessionChatWorkspace: View"))
        XCTAssertTrue(detailSource.contains("ChatViewHost(sessionId: sessionId)"))
        XCTAssertTrue(detailSource.contains("Label(\"Sessions\", systemImage: \"chevron.left\")"))
        XCTAssertTrue(detailSource.contains("Label(\"Open in \\(ownerName)\""))
        XCTAssertTrue(detailSource.contains("Image(systemName: \"ellipsis\")"))
        XCTAssertFalse(splitSource.contains(".sheet("))
        XCTAssertFalse(detailSource.contains("SessionBriefView"))
        XCTAssertFalse(detailSource.contains("HistoricalSessionInspector"))
        XCTAssertFalse(detailSource.contains("Inspect transcript"))
    }

    func testChatHeaderKeepsOwnerAndOptionalDetailsOneClickAway() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertTrue(source.contains("Button(action: onOpenOriginal)"))
        XCTAssertTrue(source.contains("Button(action: onBack)"))
        XCTAssertTrue(source.contains("ChatTheme.headerBg"))
    }

    func testChatHeaderUsesCompactSingleLineSessionIdentity() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))
        let header = try sourceSlice(
            source,
            from: "private func chatHeader",
            to: "private var unavailableHeader"
        )

        XCTAssertTrue(header.contains("SessionStatusDot(session: session, diameter: 7"))
        XCTAssertTrue(header.contains("Text(session.displayTitle)"))
        XCTAssertTrue(header.contains(".frame(height: 46)"))
        XCTAssertTrue(header.contains(".help(SessionPhaseHelpers.phaseDescription(for: session.phase))"))
        XCTAssertTrue(header.contains(".accessibilityLabel(sessionStatusAccessibilityLabel(session))"))
        XCTAssertFalse(header.contains("AgentBrandLogo"))
        XCTAssertFalse(header.contains("VStack("))
        XCTAssertFalse(header.contains("agentDisplayName(for: session)"))
        XCTAssertFalse(header.contains("session.bestProjectName"))
        XCTAssertFalse(header.contains("Divider()"))
    }

    func testChatHeaderKeepsOwnerActionSecondaryAndDetailsInOverflow() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))
        let header = try sourceSlice(
            source,
            from: "private func chatHeader",
            to: "private var unavailableHeader"
        )
        let ownerAction = try XCTUnwrap(header.range(of: "if canOpenOriginal"))
        let detailsOverflow = try XCTUnwrap(header.range(of: "detailsMenu(session)"))

        XCTAssertLessThan(ownerAction.lowerBound, detailsOverflow.lowerBound)
        XCTAssertTrue(header.contains("Label(\"Open in \\(ownerName)\", systemImage: \"arrow.up.forward\")"))
        XCTAssertTrue(header.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(header.contains(".controlSize(.small)"))
        XCTAssertFalse(header.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(header.contains(".tint(ChatTheme.link)"))
        XCTAssertTrue(source.contains("Image(systemName: \"ellipsis\")"))
        XCTAssertTrue(source.contains(".menuIndicator(.hidden)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Session details\")"))
        XCTAssertTrue(source.contains(".help(\"Session details\")"))
        XCTAssertFalse(source.contains("Label(\"Details\", systemImage: \"info.circle\")"))
    }

    func testTechnicalSummaryCardsDoNotPrecedeChat() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Window/SessionWorkspaceDetail.swift"))

        XCTAssertFalse(source.contains("Latest activity"))
        XCTAssertFalse(source.contains("Session context"))
        XCTAssertFalse(source.contains("Started with"))
        XCTAssertFalse(source.contains("SessionInspectorPolicy"))
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
