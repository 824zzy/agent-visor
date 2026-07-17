import XCTest
@testable import AgentVisorCore

final class CursorTranscriptParserTests: XCTestCase {
    /// Each line in cursor-agent's JSONL is a single message:
    ///   {"role": "user|assistant", "message": {"content": [{"type": ..., ...}]}}
    /// User text is wrapped in `<timestamp>...</timestamp>\n<user_query>...</user_query>`.
    /// Tool calls are `{"type": "tool_use", "name": ..., "input": {...}}`. No
    /// timestamps are stored per-line — the only timestamp signal is the user
    /// `<timestamp>` XML, which we parse opportunistically.
    func testParsesMinimalUserAssistantPair() {
        let jsonl = """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, May 31, 2026, 2:19 AM (UTC-7)</timestamp>\\n<user_query>\\nhi\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Hi! What can I help you with today?"}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].blocks, [.text("hi")])
        XCTAssertEqual(parsed.messages[1].role, .assistant)
        XCTAssertEqual(parsed.messages[1].blocks, [.text("Hi! What can I help you with today?")])
    }

    func testStripsUserQueryXMLWrapper() {
        let jsonl = """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, May 31, 2026, 2:19 AM (UTC-7)</timestamp>\\n<user_query>\\nWrite a hello world\\n</user_query>"}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].blocks, [.text("Write a hello world")])
    }

    func testToolUseBlockExtractsNameAndInput() {
        let jsonl = """
        {"role":"assistant","message":{"content":[{"type":"text","text":"Let me check"},{"type":"tool_use","name":"Shell","input":{"command":"ls -la","description":"List files"}}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].role, .assistant)
        XCTAssertEqual(parsed.messages[0].blocks.count, 2)
        XCTAssertEqual(parsed.messages[0].blocks[0], .text("Let me check"))

        guard case .toolCall(let tool) = parsed.messages[0].blocks[1] else {
            return XCTFail("expected toolCall block")
        }
        XCTAssertEqual(tool.name, "Shell")
        XCTAssertEqual(tool.input["command"], "ls -la")
        XCTAssertEqual(tool.input["description"], "List files")
        XCTAssertFalse(tool.id.isEmpty, "tool calls must get a stable synthetic id")
    }

    func testMultipleToolUsesGetDistinctIDs() {
        let jsonl = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"pwd"}},{"type":"tool_use","name":"Read","input":{"path":"/tmp/x"}}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        var ids: [String] = []
        for block in parsed.messages.first?.blocks ?? [] {
            if case .toolCall(let tool) = block { ids.append(tool.id) }
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testSkipsUnknownLines() {
        let jsonl = """
        not json
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>x</timestamp>\\n<user_query>\\nhi\\n</user_query>"}]}}
        {"role":"system","message":{"content":[{"type":"text","text":"ignored"}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.count, 2)
        // System lines are kept (they may surface useful state); UI dispatch
        // can hide them. The contract here is "preserve everything that
        // parses; don't crash on garbage."
    }

    func testAssistantTextWithoutWrapperPassesThrough() {
        let jsonl = """
        {"role":"assistant","message":{"content":[{"type":"text","text":"Plain text answer."}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.first?.blocks, [.text("Plain text answer.")])
    }

    func testCompletedToolIdsCoverEveryToolCall() {
        // Cursor doesn't store tool_result blocks in the rollout, so every
        // tool call we see is treated as completed (the matching response
        // happens out-of-band and the agent moves on). Mirrors how Codex
        // treats `function_call_output` rows but degenerate.
        let jsonl = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"ls"}}]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"/x"}}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.completedToolIds.count, 2)

        // Pull tool ids back out and confirm the set matches.
        var seenIds = Set<String>()
        for message in parsed.messages {
            for block in message.blocks {
                if case .toolCall(let tool) = block {
                    seenIds.insert(tool.id)
                }
            }
        }
        XCTAssertEqual(parsed.completedToolIds, seenIds)
    }

    func testParsesUserTimestampHeader() {
        let jsonl = """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, May 31, 2026, 2:19 AM (UTC-7)</timestamp>\\n<user_query>\\nhi\\n</user_query>"}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.count, 1)
        // Only requirement: the timestamp must be a real Date. Parsing a
        // human-readable header into a precise Date is brittle, but a
        // best-effort fallback (Date()) is fine for ordering.
        XCTAssertNotNil(parsed.messages.first?.timestamp)
    }

    /// Regression: the on-disk JSONL is `user, assistant, user, assistant`
    /// in temporal order. Parser used to give assistants a 1970-epoch
    /// fallback timestamp while user messages got real dates from their
    /// `<timestamp>` header — when SessionStore later sorted chatItems by
    /// timestamp every assistant collapsed above every user. The fix
    /// anchors the running fallback to each user's real header so
    /// subsequent assistant lines stay close to the turn that prompted
    /// them, and the sort is stable.
    func testInterleavedTimestampsKeepTurnOrderAfterSort() {
        let jsonl = """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, May 31, 2026, 2:19 AM (UTC-7)</timestamp>\\n<user_query>\\nhi\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Hi! What can I help you with today?"}]}}
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, May 31, 2026, 3:23 AM (UTC-7)</timestamp>\\n<user_query>\\nhi\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Hi again!"}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        XCTAssertEqual(parsed.messages.count, 4)

        let sorted = parsed.messages.sorted { $0.timestamp < $1.timestamp }
        let roles = sorted.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .user, .assistant])
    }

    func testInputDictNonStringValuesGetStringified() {
        let jsonl = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://x","timeout_ms":500,"follow_redirects":true}}]}}
        """

        let parsed = CursorTranscriptParser.parse(data: Data(jsonl.utf8))
        guard case .toolCall(let tool) = parsed.messages.first?.blocks.first else {
            return XCTFail("expected toolCall")
        }
        XCTAssertEqual(tool.input["url"], "https://x")
        XCTAssertEqual(tool.input["timeout_ms"], "500")
        XCTAssertEqual(tool.input["follow_redirects"], "true")
    }
}
