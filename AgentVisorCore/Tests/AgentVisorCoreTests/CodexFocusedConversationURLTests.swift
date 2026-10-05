import XCTest
@testable import AgentVisorCore

final class CodexFocusedConversationURLTests: XCTestCase {
    func testIdentifiesOnlyAnExactLocalConversationDocument() {
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for url in ["codex://threads/\(id)", "app://-/local/\(id)", "app://-/hotkey-window/thread/\(id)"] {
            XCTAssertEqual(CodexFocusedConversationURL.threadId(url), id)
        }
        for url in ["app://-/remote/\(id)", "https://example.com/local/\(id)",
                    "codex://threads/\(id)?view=review", "app://-/local/invalid", "app://-/local/\(id)/other"] {
            XCTAssertNil(CodexFocusedConversationURL.threadId(url))
        }
    }
}
