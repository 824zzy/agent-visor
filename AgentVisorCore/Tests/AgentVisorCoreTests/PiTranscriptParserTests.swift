import XCTest
@testable import AgentVisorCore

final class PiTranscriptParserTests: XCTestCase {
    func testParsesOnlyTheLatestActiveBranch() throws {
        let jsonl = """
        {"type":"session","version":3,"id":"session-1","timestamp":"2026-07-22T07:04:30.591Z","cwd":"/tmp/project"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-07-22T07:04:31.000Z","message":{"role":"user","content":"Start"}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-07-22T07:04:32.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Choose a path"}],"provider":"openai","model":"gpt-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"stop"}}
        {"type":"message","id":"u-old","parentId":"a1","timestamp":"2026-07-22T07:04:33.000Z","message":{"role":"user","content":"Abandoned branch"}}
        {"type":"message","id":"a-old","parentId":"u-old","timestamp":"2026-07-22T07:04:34.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Old answer"}],"provider":"openai","model":"gpt-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"stop"}}
        {"type":"session_info","id":"name-old","parentId":"a-old","timestamp":"2026-07-22T07:04:34.500Z","name":"Abandoned name"}
        {"type":"message","id":"u-new","parentId":"a1","timestamp":"2026-07-22T07:04:35.000Z","message":{"role":"user","content":"Active branch"}}
        {"type":"session_info","id":"name-new","parentId":"u-new","timestamp":"2026-07-22T07:04:36.000Z","name":"Active name"}
        """

        let parsed = PiTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.metadata, PiTranscriptMetadata(
            sessionId: "session-1",
            cwd: "/tmp/project",
            createdAt: ISO8601DateFormatter.piTest.date(from: "2026-07-22T07:04:30.591Z")!
        ))
        XCTAssertEqual(parsed.messages.map(\.blocks), [
            [.text("Start")],
            [.text("Choose a path")],
            [.text("Active branch")],
        ])
        XCTAssertEqual(parsed.sessionName, "Active name")
    }

    func testParsesPiMessagesToolsMetadataAndSummaries() throws {
        let jsonl = """
        {"type":"session","version":3,"id":"session-2","timestamp":"2026-07-22T08:00:00.000Z","cwd":"/tmp/rich"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-07-22T08:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Inspect"},{"type":"image","data":"abc","mimeType":"image/png"}]}}
        {"type":"model_change","id":"model","parentId":"u1","timestamp":"2026-07-22T08:00:02.000Z","provider":"openai-codex","modelId":"gpt-5.6"}
        {"type":"thinking_level_change","id":"effort","parentId":"model","timestamp":"2026-07-22T08:00:03.000Z","thinkingLevel":"high"}
        {"type":"message","id":"a1","parentId":"effort","timestamp":"2026-07-22T08:00:04.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reasoning"},{"type":"text","text":"Running"},{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"pwd","timeout":5}}],"provider":"openai-codex","model":"gpt-5.6","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":3,"totalTokens":20},"stopReason":"toolUse"}}
        not-json
        {"type":"message","id":"r1","parentId":"a1","timestamp":"2026-07-22T08:00:05.000Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"bash","content":[{"type":"text","text":"/tmp/rich"}],"isError":false}}
        {"type":"message","id":"a2","parentId":"r1","timestamp":"2026-07-22T08:00:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"provider":"openai-codex","model":"gpt-5.6","usage":{"input":12,"output":2,"cacheRead":4,"cacheWrite":0,"totalTokens":18},"stopReason":"stop"}}
        {"type":"branch_summary","id":"summary","parentId":"a2","timestamp":"2026-07-22T08:00:07.000Z","fromId":"old","summary":"Earlier branch recap"}
        {"type":"compaction","id":"compact","parentId":"summary","timestamp":"2026-07-22T08:00:08.000Z","summary":"Compact recap","tokensBefore":1000,"firstKeptEntryId":"u1"}
        {"type":"message","id":"bash","parentId":"compact","timestamp":"2026-07-22T08:00:09.000Z","message":{"role":"bashExecution","command":"git status","output":"clean","exitCode":0,"cancelled":false,"truncated":false,"timestamp":1784716809000}}
        {"type":"session_info","id":"name","parentId":"bash","timestamp":"2026-07-22T08:00:10.000Z","name":"Rich session"}
        """

        let parsed = PiTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.sessionName, "Rich session")
        XCTAssertEqual(parsed.modelName, "gpt-5.6")
        XCTAssertEqual(parsed.modelProvider, "openai-codex")
        XCTAssertEqual(parsed.effortLevel, "high")
        XCTAssertEqual(parsed.contextTokens, 18)
        XCTAssertEqual(parsed.lastTurnMarker, .completed)
        XCTAssertEqual(parsed.completedToolIds, ["call-1"])
        XCTAssertEqual(parsed.toolOutputs, ["call-1": "/tmp/rich"])
        XCTAssertEqual(parsed.messages.map(\.blocks), [
            [.text("Inspect"), .image(PiParsedImage(dataURI: "data:image/png;base64,abc"))],
            [.thinking("Reasoning"), .text("Running"), .toolCall(PiParsedToolCall(
                id: "call-1",
                name: "bash",
                input: ["command": "pwd", "timeout": "5"]
            ))],
            [.text("Done")],
            [.recap("Earlier branch recap")],
            [.compactBoundary(summary: "Compact recap", preTokens: 1000)],
            [.localCommandOutput("$ git status\nclean")],
        ])
    }

    func testErrorAssistantDoesNotReplaceLastValidContextUsage() {
        let jsonl = """
        {"type":"session","version":3,"id":"usage","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-07-22T09:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Valid"}],"provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":80,"output":20,"cacheRead":0,"cacheWrite":0,"totalTokens":100},"stopReason":"stop"}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-07-22T09:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Failed"}],"provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":900,"output":99,"cacheRead":0,"cacheWrite":0,"totalTokens":999},"stopReason":"error"}}
        """

        let parsed = PiTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.contextTokens, 100)
        XCTAssertEqual(parsed.messages.map(\.blocks), [
            [.text("Valid")],
            [.text("Failed"), .interrupted],
        ])
    }

    func testEmptyAbortedAssistantStillSurfacesInterruption() {
        let jsonl = """
        {"type":"session","version":3,"id":"aborted","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-07-22T09:00:01.000Z","message":{"role":"assistant","content":[],"provider":"openai","model":"gpt-5","stopReason":"aborted"}}
        """

        let parsed = PiTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.messages.map(\.blocks), [[.interrupted]])
    }

    func testPreservesFailedToolResultStatus() {
        let jsonl = """
        {"type":"session","version":3,"id":"failed","timestamp":"2026-07-22T09:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-07-22T09:00:01.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-failed","name":"bash","arguments":{"command":"false"}}],"provider":"openai","model":"gpt-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"stopReason":"toolUse"}}
        {"type":"message","id":"r1","parentId":"a1","timestamp":"2026-07-22T09:00:02.000Z","message":{"role":"toolResult","toolCallId":"call-failed","toolName":"bash","content":[{"type":"text","text":"exit 1"}],"isError":true}}
        """

        let parsed = PiTranscriptParser.parse(data: Data(jsonl.utf8))

        XCTAssertEqual(parsed.failedToolIds, ["call-failed"])
    }
}

private extension ISO8601DateFormatter {
    static let piTest: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
