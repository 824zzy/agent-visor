import XCTest
@testable import AgentVisorCore

final class CodexCommandOutputParserTests: XCTestCase {
    func testExitedCommandStripsEnvelopeAndKeepsOutput() {
        let raw = "Chunk ID: 5e0f6a\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 10\nOutput:\n/Users/example/Codes/ic-digital-twin\n"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "/Users/example/Codes/ic-digital-twin")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(result.isRunning)
    }

    func testRunningCommandCarriesSessionIdAndNoExitCode() {
        let raw = "Chunk ID: 16ed95\nWall time: 1.0009 seconds\nProcess running with session ID 6233\nOriginal token count: 0\nOutput:\n"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.sessionID, 6233)
        XCTAssertTrue(result.isRunning)
    }

    func testStripsAnsiEscapeSequences() {
        let raw = "Chunk ID: 8606ae\nWall time: 0.0000 seconds\nProcess exited with code 0\nOriginal token count: 19\nOutput:\n[\u{1B}[31mERROR\u{1B}[0m] - (starship::print): Under a 'dumb' terminal (TERM=dumb).\n"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "[ERROR] - (starship::print): Under a 'dumb' terminal (TERM=dumb).")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNonZeroExitCodeIsParsed() {
        let raw = "Chunk ID: aa11bb\nWall time: 0.1 seconds\nProcess exited with code 127\nOriginal token count: 3\nOutput:\ncommand not found\n"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.text, "command not found")
    }

    func testUnwrapsMcpTextContentArray() {
        let raw = "Wall time: 3.0220 seconds\nOutput:\n[{\"type\":\"text\",\"text\":\"Found 11 results\"}]"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "Found 11 results")
        XCTAssertNil(result.exitCode)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(result.isRunning)
    }

    func testJoinsMultipleMcpTextBlocksWithNewline() {
        let raw = "Wall time: 0.5 seconds\nOutput:\n[{\"type\":\"text\",\"text\":\"line one\"},{\"type\":\"text\",\"text\":\"line two\"}]"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "line one\nline two")
    }

    func testNoEnvelopeReturnsRawTextAndNoStatus() {
        let raw = "plain output, no envelope here"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "plain output, no envelope here")
        XCTAssertNil(result.exitCode)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(result.isRunning)
    }

    func testOutputContainingOutputColonInBodyIsPreserved() {
        // The envelope delimiter is the FIRST standalone "Output:" line;
        // a later "Output:" inside the real output must survive.
        let raw = "Chunk ID: c0ffee\nWall time: 0.0 seconds\nProcess exited with code 0\nOriginal token count: 5\nOutput:\nResult Output:\n42\n"

        let result = CodexCommandOutputParser.parse(raw)

        XCTAssertEqual(result.text, "Result Output:\n42")
        XCTAssertEqual(result.exitCode, 0)
    }
}
