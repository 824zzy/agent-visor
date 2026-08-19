import XCTest
@testable import AgentVisorCore

final class PiTranscriptActiveNameReaderTests: XCTestCase {
    func testFindsAnActiveNameAcrossAnOmittedLargeRecord() throws {
        let file = try makeFile(lines: [
            #"{"type":"session","version":3,"id":"session-1","timestamp":"2026-08-19T00:00:00Z","cwd":"/tmp/project"}"#,
            #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-08-19T00:00:01Z","message":{"role":"user","content":"Start"}}"#,
            #"{"type":"session_info","id":"name","parentId":"u1","timestamp":"2026-08-19T00:00:02Z","name":"donut-github"}"#,
            #"{"type":"diagnostic","id":"middle","parentId":"name","payload":""#
                + String(repeating: "x", count: 900 * 1024)
                + #""}"#,
            #"{"type":"message","id":"a1","parentId":"middle","timestamp":"2026-08-19T00:00:03Z","message":{"role":"assistant","content":"Done"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertEqual(PiTranscriptActiveNameReader.read(path: file.path), "donut-github")
    }

    func testIgnoresANameOnAnAbandonedBranch() throws {
        let file = try makeFile(lines: [
            #"{"type":"session","version":3,"id":"session-1","timestamp":"2026-08-19T00:00:00Z","cwd":"/tmp/project"}"#,
            #"{"type":"message","id":"root","parentId":null,"timestamp":"2026-08-19T00:00:01Z","message":{"role":"user","content":"Start"}}"#,
            #"{"type":"message","id":"old","parentId":"root","timestamp":"2026-08-19T00:00:02Z","message":{"role":"assistant","content":"Old"}}"#,
            #"{"type":"session_info","id":"old-name","parentId":"old","timestamp":"2026-08-19T00:00:03Z","name":"Abandoned"}"#,
            #"{"type":"message","id":"active","parentId":"root","timestamp":"2026-08-19T00:00:04Z","message":{"role":"assistant","content":"Active"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertNil(PiTranscriptActiveNameReader.read(path: file.path))
    }

    func testUsesTheLatestNameOnTheActiveBranch() throws {
        let file = try makeFile(lines: [
            #"{"type":"session","version":3,"id":"session-1","timestamp":"2026-08-19T00:00:00Z","cwd":"/tmp/project"}"#,
            #"{"type":"message","id":"root","parentId":null,"timestamp":"2026-08-19T00:00:01Z","message":{"role":"user","content":"Start"}}"#,
            #"{"type":"session_info","id":"first","parentId":"root","timestamp":"2026-08-19T00:00:02Z","name":"First"}"#,
            #"{"type":"session_info","id":"latest","parentId":"first","timestamp":"2026-08-19T00:00:03Z","name":"Latest"}"#,
            #"{"type":"message","id":"leaf","parentId":"latest","timestamp":"2026-08-19T00:00:04Z","message":{"role":"assistant","content":"Done"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertEqual(PiTranscriptActiveNameReader.read(path: file.path), "Latest")
    }

    func testAnIncompleteTrailingScalarDoesNotHideTheActiveLeaf() throws {
        let leafPrefix = #"{"type":"diagnostic","id":"active-leaf","parentId":"active-parent","payload":""#
        let activeLeaf = leafPrefix
            + String(repeating: "x", count: 65_535 - leafPrefix.utf8.count)
            + "😀"
            + #""}"#
        let file = try makeFile(lines: [
            #"{"type":"message","id":"root","parentId":null,"message":{"role":"user","content":"Start"}}"#,
            #"{"type":"message","id":"active-parent","parentId":"root","message":{"role":"assistant","content":"Active"}}"#,
            #"{"type":"session_info","id":"abandoned-name","parentId":"root","name":"Abandoned"}"#,
            activeLeaf
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertNil(
            PiTranscriptActiveNameReader.read(path: file.path),
            "The active branch has no name; a truncated scalar must not make the abandoned branch look active."
        )
    }

    private func makeFile(lines: [String]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }
}
