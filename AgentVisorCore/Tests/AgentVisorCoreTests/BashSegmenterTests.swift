import XCTest
@testable import AgentVisorCore

final class BashSegmenterTests: XCTestCase {
    func test_singleCommand_yieldsOneSafeSegment() {
        let segs = BashSegmenter.segments("ls -la")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.text, "ls -la")
        XCTAssertEqual(segs.first?.isUnsafe, false)
    }

    func test_semicolonChain_yieldsThreeSafe() {
        let segs = BashSegmenter.segments("a; b; c")
        XCTAssertEqual(segs.map(\.text), ["a", "b", "c"])
        XCTAssertTrue(segs.allSatisfy { !$0.isUnsafe })
    }

    func test_andOrChain_yieldsThreeSafe() {
        let segs = BashSegmenter.segments("a && b || c")
        XCTAssertEqual(segs.map(\.text), ["a", "b", "c"])
    }

    func test_pipeChain_yieldsTwoSafe() {
        let segs = BashSegmenter.segments("a | b")
        XCTAssertEqual(segs.map(\.text), ["a", "b"])
    }

    func test_newlineSeparatedScript_yieldsThreeSafe() {
        let segs = BashSegmenter.segments("a\nb\nc")
        XCTAssertEqual(segs.map(\.text), ["a", "b", "c"])
    }

    func test_doubleQuoteContainsSeparator_doesNotSplit() {
        let segs = BashSegmenter.segments("echo \"a; b\"")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.text, "echo \"a; b\"")
        XCTAssertEqual(segs.first?.isUnsafe, false)
    }

    func test_singleQuoteContainsSeparator_doesNotSplit() {
        let segs = BashSegmenter.segments("echo 'a | b'")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.text, "echo 'a | b'")
    }

    func test_singleQuoteContainsDollar_isNotUnsafe() {
        // The screenshot trigger: `awk '{print $1, "words"}'`. The
        // `$1` is literal inside single quotes.
        let segs = BashSegmenter.segments("awk '{print $1, \"words\"}'")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.isUnsafe, false)
    }

    func test_doubleQuoteContainsDollarParen_isUnsafe() {
        let segs = BashSegmenter.segments("echo \"$(whoami)\"")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.isUnsafe, true)
    }

    func test_unquotedDollarParen_isUnsafe() {
        let segs = BashSegmenter.segments("echo $(whoami)")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.isUnsafe, true)
    }

    func test_backtick_isUnsafe() {
        let segs = BashSegmenter.segments("echo `id`")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.isUnsafe, true)
    }

    func test_escapedQuotes_areLiteralAndSafe() {
        let segs = BashSegmenter.segments("echo \\\"hello\\\"")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.isUnsafe, false)
    }

    func test_redirectionDoesNotSplit() {
        let segs = BashSegmenter.segments("cat a > b")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.text, "cat a > b")
    }

    func test_stderrRedirectionPassesThrough() {
        let segs = BashSegmenter.segments("cat a 2>/dev/null")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.text, "cat a 2>/dev/null")
        XCTAssertEqual(segs.first?.isUnsafe, false)
    }

    func test_multilineScreenshotScript_yieldsEightSafeSegments() {
        // The user's screenshot regression. Newlines split, the awk
        // single-quoted block stays one segment, $1 inside it is literal.
        let script = """
        echo "=== file ==="
        ls -la ~/AkashicRecords/dev/telemetry/
        echo ""
        echo "=== word count ==="
        wc -w ~/AkashicRecords/dev/telemetry/llm-telemetry.md | awk '{print $1, "words"}'
        echo ""
        echo "=== _index.md dev section now ==="
        sed -n '/^## Dev/,/^## /p' ~/AkashicRecords/_index.md | head -25
        """
        let segs = BashSegmenter.segments(script)
        // 8 statements, but lines 5 and 8 each contain a pipe → +2 segments.
        XCTAssertEqual(segs.count, 10)
        XCTAssertTrue(segs.allSatisfy { !$0.isUnsafe },
                      "Got unsafe segment(s): \(segs.filter(\.isUnsafe).map(\.text))")
    }
}
