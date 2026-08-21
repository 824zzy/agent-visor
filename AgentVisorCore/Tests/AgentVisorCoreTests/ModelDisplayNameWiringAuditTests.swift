import XCTest

final class ModelDisplayNameWiringAuditTests: XCTestCase {
    func testPiCatalogDisplayNameFlowsIntoSessionPresentationMetadata() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let conversationInfo = try source(root, "AgentVisorCore/Sources/AgentVisorCore/ConversationInfo.swift")
        let piParser = try source(root, "AgentVisor/Services/Session/PiConversationParser.swift")
        let sessionStore = try source(root, "AgentVisor/Services/State/SessionStore.swift")

        XCTAssertTrue(conversationInfo.contains("let lastModelDisplayName: String?"))
        XCTAssertTrue(piParser.contains("lastModelDisplayName: catalogMetadata?.displayName"))
        XCTAssertTrue(sessionStore.contains("catalogDisplayName: info.lastModelDisplayName"))

        // The SessionState half of this rule is covered by behaviour now, in
        // SessionStateBehaviourTests: displayModelName resolution and fallback, a placeholder id
        // being ignored, and a new model clearing the previous catalog name. Those tests run the
        // code, so the text checks that used to stand in for them are gone.
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
        let windowChat = try source(root, "AgentVisor/UI/Window/WindowChatView.swift")
        let hover = try source(root, "AgentVisor/UI/Components/SessionDetailPopover.swift")
        let details = try source(root, "AgentVisor/UI/Window/SessionWorkspaceDetail.swift")

        XCTAssertTrue(status.contains("let modelDisplayName: String?"))
        XCTAssertTrue(status.contains("if let display = modelDisplayName"))
        XCTAssertFalse(status.contains("private var displayModel"))
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
