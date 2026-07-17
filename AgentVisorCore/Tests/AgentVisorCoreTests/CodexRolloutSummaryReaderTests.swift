import XCTest
@testable import AgentVisorCore

final class CodexRolloutSummaryReaderTests: XCTestCase {
    func testUsesLatestTurnContextWhenItFallsOutsideHeadAndTailWindows() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout.jsonl")
        let oldContext = #"{"timestamp":"2026-06-12T21:46:40.195Z","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}"#
        let latestContext = #"{"timestamp":"2026-07-14T05:02:36.712Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}"#
        let filler = #"{"type":"event_msg","payload":{"type":"debug","text":""#
            + String(repeating: "x", count: 300 * 1024)
            + #""}}"#
        let tokenCount = #"{"timestamp":"2026-07-14T05:09:22.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":150593},"model_context_window":258400}}}"#
        let taskStarted = #"{"timestamp":"2026-07-14T05:11:42.267Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-live"}}"#
        let contents = [oldContext, filler, latestContext, filler, tokenCount, taskStarted]
            .joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: file)

        let result = try XCTUnwrap(CodexRolloutSummaryReader.read(path: file.path))

        XCTAssertEqual(result.transcript.modelName, "gpt-5.6-sol")
        XCTAssertEqual(result.transcript.effortLevel, "ultra")
        XCTAssertEqual(result.transcript.approvalPolicy, "never")
        XCTAssertEqual(result.transcript.sandboxPolicyType, "danger-full-access")
        XCTAssertEqual(result.transcript.contextTokens, 150593)
        XCTAssertEqual(result.transcript.contextWindowTokens, 258400)
        XCTAssertEqual(result.transcript.lastTurnMarker, .started)
    }

    func testIncrementalScanKeepsPriorMetadataUntilAnAppendedTurnContextIsComplete() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout.jsonl")
        let initial = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra"}}"# + "\n"
        try Data(initial.utf8).write(to: file)
        let first = try XCTUnwrap(CodexRolloutSummaryReader.read(path: file.path))

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"turn_context","payload":{"model":"gpt-next""#.utf8))

        let partial = try XCTUnwrap(CodexRolloutSummaryReader.read(
            path: file.path,
            previousTurnContextScan: first.turnContextScan
        ))
        XCTAssertEqual(partial.transcript.modelName, "gpt-5.6-sol")
        XCTAssertEqual(partial.transcript.effortLevel, "ultra")

        try handle.write(contentsOf: Data(#", "effort":"medium"}}"#.utf8))
        let complete = try XCTUnwrap(CodexRolloutSummaryReader.read(
            path: file.path,
            previousTurnContextScan: partial.turnContextScan
        ))

        XCTAssertEqual(complete.transcript.modelName, "gpt-next")
        XCTAssertEqual(complete.transcript.effortLevel, "medium")
    }

    func testIncrementalScanCompletesTheFirstTurnContextInANewFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout.jsonl")
        try Data("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt".utf8).write(to: file)
        let partial = try XCTUnwrap(CodexTurnContextFileScanner.scan(path: file.path))
        XCTAssertNil(partial.latestRecord)

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"-next","effort":"ultra"}}"#.utf8))

        let complete = try XCTUnwrap(CodexTurnContextFileScanner.scan(
            path: file.path,
            previous: partial
        ))
        let parsed = CodexTranscriptParser.parse(data: try XCTUnwrap(complete.latestRecord))
        XCTAssertEqual(parsed.modelName, "gpt-next")
        XCTAssertEqual(parsed.effortLevel, "ultra")
    }
}
