import XCTest
@testable import AgentVisorCore

final class CodexTranscriptParserTests: XCTestCase {
    func testPermissionProfileDisabledInfersFullAccessWhenLegacyFieldsAreAbsent() throws {
        let jsonl = """
        {"timestamp":"2026-06-11T18:14:38.950Z","type":"turn_context","payload":{"permission_profile":{"type":"disabled"},"model":"gpt-5.5"}}
        """

        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.approvalPolicy, "never")
        XCTAssertEqual(parsed.sandboxPolicyType, "danger-full-access")
    }

    func testExplicitCodexPermissionFieldsWinOverPermissionProfileFallback() throws {
        let jsonl = """
        {"timestamp":"2026-06-11T18:14:38.950Z","type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"},"permission_profile":{"type":"disabled"},"model":"gpt-5.5"}}
        """

        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.approvalPolicy, "on-request")
        XCTAssertEqual(parsed.sandboxPolicyType, "workspace-write")
    }

    func testStripsCodexAttachmentPreambleFromUserMessage() throws {
        let jsonl = """
        {"timestamp":"2026-06-10T19:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Files mentioned by the user:\\n\\ncodex-clipboard-0a8bd716-19b1-4710-9cc8-99bdbb8e5c73.png: /var/folders/6j/gfpl8q6d5t1_sgk8xyf4jnp80000gn/T/codex-clipboard-0a8bd716-19b1-4710-9cc8-99bdbb8e5c73.png\\n\\nMy request for Codex:\\n\\nShe has the access. Do you think it is fine for us to ask permission from her?","images":[],"local_images":["/var/folders/6j/gfpl8q6d5t1_sgk8xyf4jnp80000gn/T/codex-clipboard-0a8bd716-19b1-4710-9cc8-99bdbb8e5c73.png"],"text_elements":[]}}
        """

        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].blocks, [
            .text("She has the access. Do you think it is fine for us to ask permission from her?"),
            .image(CodexParsedImage(source: .localPath, value: "/var/folders/6j/gfpl8q6d5t1_sgk8xyf4jnp80000gn/T/codex-clipboard-0a8bd716-19b1-4710-9cc8-99bdbb8e5c73.png"))
        ])
    }

    func testParsesImageOnlyUserMessageAsImageBlockWithoutPlaceholderText() throws {
        let jsonl = """
        {"timestamp":"2026-06-10T19:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"","images":[],"local_images":["/tmp/only.png"],"text_elements":[]}}
        """

        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].blocks, [
            .image(CodexParsedImage(source: .localPath, value: "/tmp/only.png"))
        ])
    }

    func testParsesOnlyCodexVisibleChatMessagesFromRollout() throws {
        let jsonl = """
        {"timestamp":"2026-05-28T23:24:17.564Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/tmp/project","model_provider":"openai"}}
        {"timestamp":"2026-05-28T23:24:18.000Z","type":"turn_context","payload":{"model":"gpt-5.5","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"effort":"xhigh"}}
        {"timestamp":"2026-05-28T23:24:18.250Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":258400}}
        {"timestamp":"2026-05-28T23:24:18.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\\n  <cwd>/tmp/project</cwd>\\n</environment_context>"}]}}
        {"timestamp":"2026-05-28T23:24:19.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello Codex\\n"},{"type":"input_text","text":"<image>"},{"type":"input_image","image_url":"data:image/png;base64,abc"},{"type":"input_text","text":"</image>"}]}}
        {"timestamp":"2026-05-28T23:24:19.001Z","type":"event_msg","payload":{"type":"user_message","message":"Hello Codex\\n","images":["data:image/png;base64,abc"],"local_images":[],"text_elements":[]}}
        {"timestamp":"2026-05-28T23:24:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"I'll inspect it."}]}}
        {"timestamp":"2026-05-28T23:24:21.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\\"cmd\\":\\"pwd\\",\\"yield_time_ms\\":1000}"}}
        {"timestamp":"2026-05-28T23:24:22.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"Output:\\n/tmp/project"}}
        {"timestamp":"2026-05-28T23:24:23.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done."}]}}
        {"timestamp":"2026-05-28T23:24:24.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":123456,"cached_input_tokens":1000,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":123476},"model_context_window":258400}}}
        {"timestamp":"2026-05-28T23:24:25.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":92000,"time_to_first_token_ms":1200}}
        """

        let parsed = CodexTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.metadata?.sessionId, "thread-1")
        XCTAssertEqual(parsed.metadata?.cwd, "/tmp/project")
        XCTAssertEqual(parsed.modelName, "gpt-5.5")
        XCTAssertEqual(parsed.effortLevel, "xhigh")
        XCTAssertEqual(parsed.approvalPolicy, "never")
        XCTAssertEqual(parsed.sandboxPolicyType, "danger-full-access")
        XCTAssertEqual(parsed.contextTokens, 123476)
        XCTAssertEqual(parsed.contextWindowTokens, 258400)
        XCTAssertEqual(parsed.messages.count, 5)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].blocks, [
            .text("Hello Codex"),
            .image(CodexParsedImage(source: .dataURI, value: "data:image/png;base64,abc"))
        ])
        XCTAssertEqual(parsed.messages[1].role, .system)
        XCTAssertEqual(parsed.messages[1].blocks, [.turnDuration(durationMs: 92000)])
        XCTAssertGreaterThan(parsed.messages[1].timestamp, parsed.messages[0].timestamp)
        XCTAssertLessThan(parsed.messages[1].timestamp, parsed.messages[2].timestamp)
        XCTAssertEqual(parsed.messages[2].role, .system)
        XCTAssertEqual(parsed.messages[2].blocks, [.detail("I'll inspect it.")])
        XCTAssertLessThan(parsed.messages[2].timestamp, parsed.messages[3].timestamp)
        XCTAssertEqual(parsed.messages[3].role, .system)
        XCTAssertEqual(parsed.messages[3].blocks, [
            .toolCall(CodexParsedToolCall(
                id: "call-1",
                name: "exec_command",
                kind: .shell,
                command: "pwd",
                input: ["cmd": "pwd", "yield_time_ms": "1000"]
            ))
        ])
        XCTAssertLessThan(parsed.messages[3].timestamp, parsed.messages[4].timestamp)
        XCTAssertEqual(parsed.messages[4].role, .assistant)
        XCTAssertEqual(parsed.messages[4].blocks, [.text("Done.")])
        XCTAssertEqual(parsed.completedToolIds, ["call-1"])
        XCTAssertEqual(parsed.toolOutputs["call-1"], "/tmp/project")
    }

    func testHeadTailSliceRetainsCodexSidebarSummarySignals() throws {
        let head = """
        {"timestamp":"2026-05-28T23:24:17.564Z","type":"session_meta","payload":{"id":"thread-large","cwd":"/tmp/large","model_provider":"openai"}}
        {"timestamp":"2026-05-28T23:24:18.000Z","type":"turn_context","payload":{"model":"gpt-5.5","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"effort":"high"}}
        {"timestamp":"2026-05-28T23:24:19.000Z","type":"event_msg","payload":{"type":"user_message","message":"Investigate the large rollout","images":[],"local_images":[],"text_elements":[]}}
        """
        let middle = (0..<200)
            .map { #"{"timestamp":"2026-05-28T23:30:00.000Z","type":"event_msg","payload":{"type":"debug","index":\#($0)}}"# }
            .joined(separator: "\n")
        let tail = """
        {"timestamp":"2026-05-28T23:40:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Large rollout done."}]}}
        {"timestamp":"2026-05-28T23:40:24.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":123456},"model_context_window":258400}}}
        {"timestamp":"2026-05-28T23:40:25.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":92000,"time_to_first_token_ms":1200}}
        """
        let data = Data([head, middle, tail].joined(separator: "\n").utf8)

        let sliced = JSONLHeadTailFileReader.slice(
            data: data,
            smallFileThreshold: 200,
            headBytes: UInt64(Data(head.utf8).count + 16),
            tailBytes: UInt64(Data(tail.utf8).count + 16)
        )
        let parsed = CodexTranscriptParser.parse(data: sliced)

        XCTAssertEqual(parsed.metadata?.sessionId, "thread-large")
        XCTAssertEqual(parsed.metadata?.cwd, "/tmp/large")
        XCTAssertEqual(parsed.modelName, "gpt-5.5")
        XCTAssertEqual(parsed.effortLevel, "high")
        XCTAssertEqual(parsed.approvalPolicy, "never")
        XCTAssertEqual(parsed.sandboxPolicyType, "danger-full-access")
        XCTAssertEqual(parsed.contextTokens, 123456)
        XCTAssertEqual(parsed.contextWindowTokens, 258400)
        XCTAssertEqual(parsed.messages.first?.role, .user)
        XCTAssertEqual(parsed.messages.first?.blocks, [.text("Investigate the large rollout")])
        XCTAssertEqual(parsed.messages.last?.role, .assistant)
        XCTAssertEqual(parsed.messages.last?.blocks, [.text("Large rollout done.")])
        XCTAssertEqual(parsed.lastTurnMarker, .completed)
    }
}
