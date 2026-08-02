import Foundation
import XCTest
@testable import AgentVisorCore

final class PiTranscriptSummaryReaderTests: XCTestCase {
    func testLargeFileReadsBoundedHeadAndTailAndKeepsTheActiveTail() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large-pi.jsonl")

        let session = #"{"type":"session","version":3,"id":"session-1","timestamp":"2026-07-22T07:04:30.591Z","cwd":"/tmp/project"}"#
        let first = #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-07-22T07:04:31.000Z","message":{"role":"user","content":"Start"}}"#
        let filler = #"{"type":"diagnostic","id":"middle","parentId":"u1","payload":""#
            + String(repeating: "x", count: 900 * 1024)
            + #""}"#
        let name = #"{"type":"session_info","id":"name","parentId":"middle","timestamp":"2026-07-22T07:04:32.000Z","name":"Tail name"}"#
        let answer = #"{"type":"message","id":"a1","parentId":"name","timestamp":"2026-07-22T07:04:33.000Z","message":{"role":"assistant","content":"Tail answer","provider":"openai-codex","model":"gpt-5.6-sol","usage":{"totalTokens":42},"stopReason":"stop"}}"#
        let data = Data(([session, first, filler, name, answer].joined(separator: "\n") + "\n").utf8)
        try data.write(to: file)

        let summary = try XCTUnwrap(PiTranscriptSummaryReader.read(path: file.path))

        XCTAssertLessThan(summary.sampledByteCount, data.count)
        XCTAssertLessThanOrEqual(
            summary.sampledByteCount,
            Int(JSONLHeadTailFileReader.defaultHeadBytes + JSONLHeadTailFileReader.defaultTailBytes + 1)
        )
        XCTAssertEqual(summary.transcript.metadata?.sessionId, "session-1")
        XCTAssertEqual(summary.transcript.sessionName, "Tail name")
        XCTAssertEqual(summary.transcript.modelName, "gpt-5.6-sol")
        XCTAssertEqual(summary.transcript.contextTokens, 42)
        XCTAssertEqual(summary.transcript.messages.map(\.blocks), [[.text("Tail answer")]])
    }
}
