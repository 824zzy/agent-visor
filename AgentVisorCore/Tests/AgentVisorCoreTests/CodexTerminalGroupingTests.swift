import XCTest
@testable import AgentVisorCore

final class CodexTerminalGroupingTests: XCTestCase {
    private func toolCalls(_ t: CodexParsedTranscript) -> [CodexParsedToolCall] {
        t.messages.flatMap { msg in
            msg.blocks.compactMap { block -> CodexParsedToolCall? in
                if case .toolCall(let c) = block { return c }
                return nil
            }
        }
    }

    func testShortExecExposesCommandCleanOutputAndExitStatus() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\\"cmd\\":\\"pwd\\"}"}}
        {"timestamp":"2026-06-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"Chunk ID: x\\nWall time: 0.0 seconds\\nProcess exited with code 0\\nOriginal token count: 10\\nOutput:\\n/tmp/proj\\n"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        let calls = toolCalls(parsed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].kind, .shell)
        XCTAssertEqual(calls[0].command, "pwd")
        XCTAssertEqual(parsed.toolOutputs["call-1"], "/tmp/proj")
        XCTAssertEqual(parsed.toolStatuses["call-1"], CodexToolStatus(exitCode: 0, isRunning: false))
        XCTAssertTrue(parsed.completedToolIds.contains("call-1"))
    }

    func testLongRunningExecFoldsWriteStdinPolls() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-exec","arguments":"{\\"cmd\\":\\"npm run build\\"}"}}
        {"timestamp":"2026-06-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-exec","output":"Chunk ID: a\\nWall time: 1.0 seconds\\nProcess running with session ID 42\\nOriginal token count: 0\\nOutput:\\nBuilding...\\n"}}
        {"timestamp":"2026-06-01T00:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"write_stdin","call_id":"call-w1","arguments":"{\\"session_id\\":42,\\"chars\\":\\"\\"}"}}
        {"timestamp":"2026-06-01T00:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-w1","output":"Chunk ID: b\\nWall time: 1.0 seconds\\nProcess running with session ID 42\\nOriginal token count: 5\\nOutput:\\nstill building\\n"}}
        {"timestamp":"2026-06-01T00:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"write_stdin","call_id":"call-w2","arguments":"{\\"session_id\\":42,\\"chars\\":\\"\\"}"}}
        {"timestamp":"2026-06-01T00:00:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-w2","output":"Chunk ID: c\\nWall time: 0.0 seconds\\nProcess exited with code 0\\nOriginal token count: 3\\nOutput:\\ndone\\n"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        let calls = toolCalls(parsed)
        XCTAssertEqual(calls.count, 1, "write_stdin polls must be folded into the exec session")
        XCTAssertEqual(calls[0].id, "call-exec")
        XCTAssertEqual(calls[0].command, "npm run build")
        XCTAssertEqual(parsed.toolOutputs["call-exec"], "Building...\nstill building\ndone")
        XCTAssertNil(parsed.toolOutputs["call-w1"])
        XCTAssertNil(parsed.toolOutputs["call-w2"])
        XCTAssertEqual(parsed.toolStatuses["call-exec"], CodexToolStatus(exitCode: 0, isRunning: false))
        XCTAssertTrue(parsed.completedToolIds.contains("call-exec"))
        XCTAssertFalse(parsed.completedToolIds.contains("call-w1"))
        XCTAssertFalse(parsed.completedToolIds.contains("call-w2"))
    }

    func testStillRunningSessionReportsRunning() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-exec","arguments":"{\\"cmd\\":\\"tail -f log\\"}"}}
        {"timestamp":"2026-06-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-exec","output":"Chunk ID: a\\nWall time: 1.0 seconds\\nProcess running with session ID 7\\nOriginal token count: 0\\nOutput:\\nline1\\n"}}
        {"timestamp":"2026-06-01T00:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"write_stdin","call_id":"call-w1","arguments":"{\\"session_id\\":7,\\"chars\\":\\"\\"}"}}
        {"timestamp":"2026-06-01T00:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-w1","output":"Chunk ID: b\\nWall time: 1.0 seconds\\nProcess running with session ID 7\\nOriginal token count: 5\\nOutput:\\nline2\\n"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.toolOutputs["call-exec"], "line1\nline2")
        XCTAssertEqual(parsed.toolStatuses["call-exec"], CodexToolStatus(exitCode: nil, isRunning: true))
    }

    func testPendingEscalatedExecWithoutOutputStaysIncomplete() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-approval","arguments":"{\\"cmd\\":\\"swift test --package-path AgentVisorCore --filter CodexAppServerProtocolTests\\",\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"Allow SwiftPM/Xcode to use its normal cache directories outside the workspace while running the targeted Core tests.\\"}"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        let calls = toolCalls(parsed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].kind, .shell)
        XCTAssertEqual(calls[0].command, "swift test --package-path AgentVisorCore --filter CodexAppServerProtocolTests")
        XCTAssertEqual(calls[0].input["sandbox_permissions"], "require_escalated")
        XCTAssertEqual(calls[0].input["justification"], "Allow SwiftPM/Xcode to use its normal cache directories outside the workspace while running the targeted Core tests.")
        XCTAssertNil(parsed.toolOutputs["call-approval"])
        XCTAssertEqual(parsed.toolStatuses["call-approval"], CodexToolStatus(exitCode: nil, isRunning: true))
        XCTAssertFalse(parsed.completedToolIds.contains("call-approval"))
    }

    func testWriteStdinControlCharsShownAsInputMarker() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-exec","arguments":"{\\"cmd\\":\\"sleep 100\\"}"}}
        {"timestamp":"2026-06-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-exec","output":"Chunk ID: a\\nWall time: 1.0 seconds\\nProcess running with session ID 9\\nOriginal token count: 0\\nOutput:\\n"}}
        {"timestamp":"2026-06-01T00:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"write_stdin","call_id":"call-w1","arguments":"{\\"session_id\\":9,\\"chars\\":\\"\\\\u0003\\"}"}}
        {"timestamp":"2026-06-01T00:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-w1","output":"Chunk ID: b\\nWall time: 0.0 seconds\\nProcess exited with code 130\\nOriginal token count: 3\\nOutput:\\ninterrupted\\n"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.toolOutputs["call-exec"], "› ^C\ninterrupted")
        XCTAssertEqual(parsed.toolStatuses["call-exec"], CodexToolStatus(exitCode: 130, isRunning: false))
    }

    func testMcpCallKindServerAndUnwrappedOutput() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"search","namespace":"mcp__github_dotcom","call_id":"call-mcp","arguments":"{\\"query\\":\\"x\\"}"}}
        {"timestamp":"2026-06-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-mcp","output":"Wall time: 0.5 seconds\\nOutput:\\n[{\\"type\\":\\"text\\",\\"text\\":\\"3 results\\"}]"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        let calls = toolCalls(parsed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].kind, .mcp)
        XCTAssertEqual(calls[0].server, "mcp__github_dotcom")
        XCTAssertEqual(parsed.toolOutputs["call-mcp"], "3 results")
        XCTAssertEqual(parsed.toolStatuses["call-mcp"], CodexToolStatus(exitCode: nil, isRunning: false))
    }

    func testUpdatePlanIsClassifiedAsPlan() {
        let jsonl = """
        {"timestamp":"2026-06-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/p"}}
        {"timestamp":"2026-06-01T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","call_id":"call-plan","arguments":"{\\"plan\\":[{\\"step\\":\\"a\\",\\"status\\":\\"in_progress\\"}]}"}}
        """
        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        let calls = toolCalls(parsed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].kind, .plan)
    }
}
