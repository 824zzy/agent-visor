import XCTest
@testable import AgentVisorCore

/// Byte-level line iterator over JSONL Data. The hot path on huge transcripts
/// must not materialize a multi-MB String before splitting; this iterator
/// slices Data views and never decodes UTF-8 until the caller asks.
final class JSONLLineIteratorTests: XCTestCase {

    private func decode(_ slice: Data?) -> String? {
        guard let slice = slice else { return nil }
        return String(data: slice, encoding: .utf8)
    }

    func testEmptyDataYieldsNothing() {
        // Given an empty Data buffer
        let data = Data()
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then next() returns nil immediately
        XCTAssertNil(iter.next())
    }

    func testSingleLineWithoutTrailingNewlineYieldsThatLine() {
        // Given a buffer with one line and no trailing newline
        let data = Data("hello".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then first yields "hello" and second is nil
        XCTAssertEqual(decode(iter.next()), "hello")
        XCTAssertNil(iter.next())
    }

    func testSingleLineWithTrailingNewlineYieldsLineWithoutNewline() {
        // Given a buffer with one line ending in LF
        let data = Data("hello\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then the LF is stripped and iteration ends
        XCTAssertEqual(decode(iter.next()), "hello")
        XCTAssertNil(iter.next())
    }

    func testTwoLinesYieldsBothInOrder() {
        // Given two LF-separated lines
        let data = Data("a\nbb\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then order is preserved and iteration terminates
        XCTAssertEqual(decode(iter.next()), "a")
        XCTAssertEqual(decode(iter.next()), "bb")
        XCTAssertNil(iter.next())
    }

    func testCRLFLineEndingsStripCR() {
        // Given CRLF-terminated lines (Windows-style — JSONL on disk shouldn't
        // have these, but the iterator strips trailing \r for safety)
        let data = Data("alpha\r\nbeta\r\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then the \r is stripped, leaving the bare content
        XCTAssertEqual(decode(iter.next()), "alpha")
        XCTAssertEqual(decode(iter.next()), "beta")
        XCTAssertNil(iter.next())
    }

    func testBlankLinesAreSkipped() {
        // Given a buffer with consecutive LFs producing empty lines
        let data = Data("a\n\nb\n\n\nc\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then only non-empty lines are yielded
        XCTAssertEqual(decode(iter.next()), "a")
        XCTAssertEqual(decode(iter.next()), "b")
        XCTAssertEqual(decode(iter.next()), "c")
        XCTAssertNil(iter.next())
    }

    func testTrailingContentWithoutNewlineYieldsLastLine() {
        // Given a buffer where the last line is unterminated (crash-truncated
        // JSONL — the parser should still see the line)
        let data = Data("first\nsecond".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then the trailing partial line still comes through
        XCTAssertEqual(decode(iter.next()), "first")
        XCTAssertEqual(decode(iter.next()), "second")
        XCTAssertNil(iter.next())
    }

    func testMultibyteUTF8LineStaysIntact() {
        // Given a buffer with multibyte UTF-8 inside a line
        let line = "日本語 🌸 emoji"
        let data = Data("\(line)\nascii\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then the multibyte line decodes to the same String round-trip
        XCTAssertEqual(decode(iter.next()), line)
        XCTAssertEqual(decode(iter.next()), "ascii")
    }

    func testOneLineLargerThanOneMegabyteIsReturnedIntact() {
        // Given a single line bigger than the chunked-read threshold
        let big = String(repeating: "x", count: 2_000_000)
        let data = Data("\(big)\nshort\n".utf8)
        // When iterated
        var iter = JSONLLineIterator(data: data)
        // Then the 2 MB line is fully returned and the next line follows
        XCTAssertEqual(iter.next()?.count, 2_000_000)
        XCTAssertEqual(decode(iter.next()), "short")
    }

    func testForInLoopProducesSameSequenceAsManualNext() {
        // Given a buffer with three lines
        let data = Data("one\ntwo\nthree\n".utf8)
        // When iterated via for-in (Sequence conformance)
        var collected: [String] = []
        for slice in JSONLLineIterator(data: data) {
            if let s = String(data: slice, encoding: .utf8) {
                collected.append(s)
            }
        }
        // Then the result matches the manual-next order
        XCTAssertEqual(collected, ["one", "two", "three"])
    }

    func testContainsBytesPrefilterMatchesWithoutDecode() {
        // Given a Data line that contains a known marker byte sequence —
        // callers use Data.range(of:) as a cheap prefilter before paying
        // the JSONDecoder cost on the line.
        let data = Data("{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n".utf8)
        let marker = Data("\"compact_boundary\"".utf8)
        var iter = JSONLLineIterator(data: data)
        let line = iter.next()
        // When the caller searches the line bytes for the marker
        let contains = line?.range(of: marker) != nil
        // Then the prefilter hits without a String materialization
        XCTAssertTrue(contains)
    }
}
