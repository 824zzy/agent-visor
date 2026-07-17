import XCTest
@testable import AgentVisorCore

final class CodexToolActivitySummarizerTests: XCTestCase {
    private func shell(_ command: String, id: String = UUID().uuidString) -> CodexParsedToolCall {
        CodexParsedToolCall(id: id, name: "exec_command", kind: .shell, command: command, input: ["cmd": command])
    }
    private func mcp(_ name: String) -> CodexParsedToolCall {
        CodexParsedToolCall(id: UUID().uuidString, name: name, kind: .mcp, server: "mcp__x", input: [:])
    }

    func testCategorizesReadVerbsAsExplore() {
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "sed -n '1,20p' foo.py"), .explore)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "rg pattern src"), .explore)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "nl -ba file"), .explore)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "cat README.md"), .explore)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "ls -la"), .explore)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "find . -name '*.py'"), .explore)
    }

    func testCategorizesOtherVerbsAsRun() {
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "git status"), .run)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "uv run pytest"), .run)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "curl https://x"), .run)
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: ""), .run)
    }

    func testCategoryUsesBasenameOfVerb() {
        XCTAssertEqual(CodexToolActivitySummarizer.category(forCommand: "/usr/bin/sed -n 1p f"), .explore)
    }

    func testSummaryCombinesExploredAndRan() {
        let activity = CodexToolActivitySummarizer.summarize([
            shell("sed -n 1p a"),
            shell("rg foo"),
            shell("git commit -m x"),
            mcp("search"),
        ])
        XCTAssertEqual(activity.exploredCount, 2)
        XCTAssertEqual(activity.ranCount, 2)
        XCTAssertEqual(activity.totalCount, 4)
        XCTAssertEqual(activity.summary, "Explored 2 files · Ran 2 commands")
    }

    func testSummaryExploredOnlySingularPluralization() {
        XCTAssertEqual(CodexToolActivitySummarizer.summarize([shell("cat a")]).summary, "Explored 1 file")
    }

    func testSummaryRanOnlyPluralization() {
        XCTAssertEqual(CodexToolActivitySummarizer.summarize([shell("git push"), shell("uv sync")]).summary, "Ran 2 commands")
    }
}
