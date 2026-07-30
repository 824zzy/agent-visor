import XCTest

final class ChatHistoryContentRailWiringAuditTests: XCTestCase {
    func testHistoryRowsMeasureAndRenderInsideTheSameResolvedRail() throws {
        let source = try repositorySource("AgentVisor/UI/Window/ChatTableView.swift")
        let layout = try sourceSlice(
            source,
            from: "private func layoutRows()",
            to: "override var intrinsicContentSize"
        )

        XCTAssertTrue(layout.contains("MainContentRailLayout.resolve(containerWidth: bounds.width)"))
        XCTAssertTrue(layout.contains("width: rail.width"))
        XCTAssertTrue(layout.contains("x: rail.leading"))
        XCTAssertFalse(layout.contains("ChatTableHorizontalPadding"))
    }

    func testMessageRolesUseTheRailInsteadOfIndependentWidthFrames() throws {
        let source = try repositorySource("AgentVisor/UI/Views/ChatView.swift")
        let userMessage = try sourceSlice(
            source,
            from: "struct UserMessageView: View",
            to: "struct ImageMessageView: View"
        )
        let assistantMessage = try sourceSlice(
            source,
            from: "struct AssistantMessageView: View",
            to: "// MARK: - Processing Indicator"
        )

        XCTAssertFalse(source.contains("ChatMessageReadableWidth"))
        XCTAssertTrue(userMessage.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(userMessage.contains("Spacer(minLength: 60)"))
        XCTAssertTrue(assistantMessage.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(assistantMessage.contains("Spacer(minLength: 60)"))
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
