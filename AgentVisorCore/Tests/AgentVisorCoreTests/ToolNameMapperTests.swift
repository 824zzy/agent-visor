import XCTest
@testable import AgentVisorCore

final class ToolNameMapperTests: XCTestCase {
    func testClaudeCodeReadMapsToCanonicalRead() {
        XCTAssertEqual(
            ToolNameMapper.canonical(for: "Read", agent: .claudeCode),
            .read
        )
    }

    func testUnknownToolFallsBackToGenericWithRawName() {
        XCTAssertEqual(
            ToolNameMapper.canonical(for: "Nonexistent", agent: .claudeCode),
            .generic(name: "Nonexistent")
        )
    }

    func testMCPToolNameSplitsIntoServerAndTool() {
        XCTAssertEqual(
            ToolNameMapper.canonical(
                for: "mcp__github__create_pull_request",
                agent: .claudeCode
            ),
            .mcp(server: "github", tool: "create_pull_request")
        )
    }

    func testClaudeCodeFullToolVocabularyMaps() {
        // Lock in every claude-code tool name the existing ChatView and
        // ConversationParser switches dispatch on. If a tool is added or
        // renamed upstream, this test surfaces it before the migration
        // drops a case on the floor.
        let expected: [(String, CanonicalTool)] = [
            ("Read", .read),
            ("Edit", .edit),
            ("MultiEdit", .edit),
            ("Write", .write),
            ("Bash", .bash),
            ("Grep", .grep),
            ("Glob", .glob),
            ("TodoWrite", .todoWrite),
            ("Task", .task),
            ("WebFetch", .webFetch),
            ("WebSearch", .webSearch),
            ("AskUserQuestion", .askUserQuestion),
            ("BashOutput", .bashOutput),
            ("KillShell", .killShell),
            ("ExitPlanMode", .exitPlanMode),
            ("EnterPlanMode", .enterPlanMode),
        ]
        for (raw, want) in expected {
            XCTAssertEqual(
                ToolNameMapper.canonical(for: raw, agent: .claudeCode),
                want,
                "claude-code \"\(raw)\" should map to \(want)"
            )
        }
    }

    func testAuggieDoesNotInheritClaudeCodeVocabulary() {
        // The mapper must dispatch on agent. Until Phase 3 adds an Auggie
        // table, asking for any tool with `agent: .auggie` should fall
        // through to `.generic`. If this test starts failing because
        // someone wired claude-code's table into the auggie path, that's
        // a bug.
        XCTAssertEqual(
            ToolNameMapper.canonical(for: "Read", agent: .auggie),
            .generic(name: "Read")
        )
    }

    func testMCPToolWithMultipleUnderscoresInToolName() {
        // The tool portion can contain underscores (e.g. `get_file_contents`)
        // and we must not lose them. Only the first `__` separator splits
        // server from tool.
        XCTAssertEqual(
            ToolNameMapper.canonical(
                for: "mcp__atlassian-jira__jira_get_issue_dates",
                agent: .claudeCode
            ),
            .mcp(server: "atlassian-jira", tool: "jira_get_issue_dates")
        )
    }
}
