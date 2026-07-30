import XCTest

final class ModelDisplayNameWiringAuditTests: XCTestCase {
    func testPiCatalogDisplayNameFlowsIntoSessionPresentationMetadata() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let conversationInfo = try source(root, "AgentVisor/Services/Session/ConversationParser.swift")
        let piParser = try source(root, "AgentVisor/Services/Session/PiConversationParser.swift")
        let sessionState = try source(root, "AgentVisor/Models/SessionState.swift")
        let sessionStore = try source(root, "AgentVisor/Services/State/SessionStore.swift")

        XCTAssertTrue(conversationInfo.contains("let lastModelDisplayName: String?"))
        XCTAssertTrue(piParser.contains("lastModelDisplayName: catalogMetadata?.displayName"))
        XCTAssertTrue(sessionState.contains("var modelDisplayName: String?"))
        XCTAssertTrue(sessionState.contains("var displayModelName: String?"))
        XCTAssertTrue(sessionState.contains("if modelName != modelID"))
        XCTAssertTrue(sessionState.contains("modelDisplayName = nil"))
        XCTAssertTrue(sessionStore.contains("catalogDisplayName: info.lastModelDisplayName"))
    }

    func testCodexCatalogDisplayNameFlowsIntoConversationMetadataReadOnly() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let reader = try source(root, "AgentVisor/Services/Session/CodexModelCatalogReader.swift")
        let builder = try source(root, "AgentVisor/Services/Session/CodexConversationInfoBuilder.swift")
        let parser = try source(root, "AgentVisor/Services/Session/CodexConversationParser.swift")
        let summary = try source(root, "AgentVisor/Services/Session/CodexConversationSummary.swift")

        XCTAssertTrue(reader.contains("models_cache.json"))
        XCTAssertTrue(reader.contains("CodexModelCatalogResolver.displayName("))
        XCTAssertFalse(reader.contains("createDirectory"))
        XCTAssertFalse(reader.contains("write("))
        XCTAssertTrue(builder.contains("lastModelDisplayName: modelDisplayName"))
        XCTAssertTrue(parser.contains("CodexModelCatalogReader.displayName(for: parsed.modelName)"))
        XCTAssertTrue(summary.contains("CodexModelCatalogReader.displayName(for: parsed.modelName)"))
    }

    func testEveryUserFacingSurfaceConsumesTheResolvedSessionLabel() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let status = try source(root, "AgentVisor/UI/Components/ChatStatusBar.swift")
        let chat = try source(root, "AgentVisor/UI/Views/ChatView.swift")
        let windowChat = try source(root, "AgentVisor/UI/Window/WindowChatView.swift")
        let hover = try source(root, "AgentVisor/UI/Components/SessionDetailPopover.swift")
        let details = try source(root, "AgentVisor/UI/Window/SessionWorkspaceDetail.swift")

        XCTAssertTrue(status.contains("let modelDisplayName: String?"))
        XCTAssertTrue(status.contains("if let display = modelDisplayName"))
        XCTAssertFalse(status.contains("private var displayModel"))
        XCTAssertTrue(chat.contains("modelDisplayName: session.displayModelName"))
        XCTAssertTrue(windowChat.contains("modelDisplayName: session.displayModelName"))
        XCTAssertTrue(hover.contains("modelDisplayName: session.displayModelName"))
        XCTAssertTrue(details.contains("Text(\"Model: \\(displayModelName)\")"))
        XCTAssertTrue(details.contains("Text(\"Model ID: \\(modelID)\")"))
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
