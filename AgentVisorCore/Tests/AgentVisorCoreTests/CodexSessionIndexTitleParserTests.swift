import XCTest
@testable import AgentVisorCore

final class CodexSessionIndexTitleParserTests: XCTestCase {
    func testLatestRenameWins() {
        let jsonl = """
        {"id":"thread-1","thread_name":"Initial title"}
        {"id":"thread-2","thread_name":"Other"}
        {"id":"thread-1","thread_name":"Latest title"}
        {"id":"thread-3","thread_name":""}
        not json
        """

        XCTAssertEqual(
            CodexSessionIndexTitleParser.titlesByThreadId(from: jsonl),
            ["thread-1": "Latest title", "thread-2": "Other"]
        )
    }
}
