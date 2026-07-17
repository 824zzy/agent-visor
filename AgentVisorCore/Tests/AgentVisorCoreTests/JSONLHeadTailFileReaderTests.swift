import XCTest
@testable import AgentVisorCore

final class JSONLHeadTailFileReaderTests: XCTestCase {
    func testSmallDataReturnsOriginalBytes() {
        let data = Data("one\ntwo\n".utf8)

        let sliced = JSONLHeadTailFileReader.slice(
            data: data,
            smallFileThreshold: 100,
            headBytes: 4,
            tailBytes: 4
        )

        XCTAssertEqual(sliced, data)
    }

    func testLargeDataKeepsOnlyCompleteHeadAndTailLines() {
        let data = Data("head-1\nhead-2\nmiddle-1\nmiddle-2\ntail-1\ntail-2\n".utf8)

        let sliced = JSONLHeadTailFileReader.slice(
            data: data,
            smallFileThreshold: 10,
            headBytes: 10,
            tailBytes: 16
        )

        XCTAssertEqual(String(data: sliced, encoding: .utf8), "head-1\ntail-1\ntail-2\n")
    }

    func testLargeFileReadMatchesInMemorySlice() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout.jsonl")
        let data = Data("head-1\nhead-2\nmiddle-1\nmiddle-2\ntail-1\ntail-2\n".utf8)
        try data.write(to: file)

        let fromFile = JSONLHeadTailFileReader.read(
            path: file.path,
            smallFileThreshold: 10,
            headBytes: 10,
            tailBytes: 16
        )

        XCTAssertEqual(String(data: fromFile ?? Data(), encoding: .utf8), "head-1\ntail-1\ntail-2\n")
    }
}
