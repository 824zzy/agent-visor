import XCTest

final class ChatUserPromptBubbleLayoutAuditTests: XCTestCase {
    func testShortPromptsHugContentBeforeLongPromptsUseWrappingFallback() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Views/ChatView.swift"))
        let userMessage = try sourceSlice(
            source,
            from: "struct UserMessageView: View",
            to: "struct ImageMessageView: View"
        )

        XCTAssertTrue(
            userMessage.contains("ViewThatFits(in: .horizontal)"),
            "User prompts need a content-hugging candidate and a constrained wrapping fallback"
        )
        XCTAssertTrue(
            userMessage.contains("userMessageBubble(p)\n                        .fixedSize(horizontal: true, vertical: false)\n                    userMessageBubble(p)"),
            "The natural-width bubble must be tried before the wrapping bubble"
        )
        XCTAssertTrue(
            userMessage.contains("Spacer(minLength: 60)"),
            "The trailing user role keeps a clear leading separation inside the shared rail"
        )
        XCTAssertFalse(
            userMessage.contains("ChatMessageReadableWidth"),
            "The shared content rail, not a message-specific frame, must constrain long prompts"
        )
    }

    func testChatContractRejectsDecorativeLeadingSpaceInShortPromptBubbles() throws {
        let contract = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("docs/session-browser-ui.md"))

        XCTAssertTrue(contract.contains("User prompts are trailing, content-hugging bubbles inside the rail."))
        XCTAssertTrue(contract.contains("rounded background never expands merely because the rail has spare width"))
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
