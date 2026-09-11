import XCTest
@testable import AgentVisorCore

final class ClaudeLocalCommandParserTests: XCTestCase {

    // Verbatim `content` of the two `system`/`local_command` rows that
    // claude-code 2.1.268 writes for `/rename cc-misc`, indentation included.
    private let renameEcho = """
    <command-name>/rename</command-name>
                <command-message>rename</command-message>
                <command-args>cc-misc</command-args>
    """
    private let renameOutput = "<local-command-stdout>Session renamed to: cc-misc</local-command-stdout>"

    // MARK: - Invocation echo

    func testEchoRowBecomesTheTypedCommand() {
        let record = ClaudeLocalCommandParser.parse(renameEcho)
        XCTAssertEqual(record.invocation, "/rename cc-misc")
        XCTAssertNil(record.output)
        XCTAssertEqual(record.displayLines, ["/rename cc-misc"])
    }

    func testEchoRowNeverLeaksMarkup() {
        for line in ClaudeLocalCommandParser.parse(renameEcho).displayLines {
            XCTAssertFalse(line.contains("<"), "leaked markup: \(line)")
            XCTAssertFalse(line.contains("command-"), "leaked tag name: \(line)")
        }
    }

    func testEchoWithoutArgsIsJustTheCommand() {
        let input = """
        <command-name>/context</command-name>
                    <command-message>context</command-message>
                    <command-args></command-args>
        """
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).displayLines, ["/context"])
    }

    func testCommandMessageAloneRendersNothing() {
        let input = "<command-message>rename</command-message>"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).displayLines, [])
    }

    func testArgsWithoutNameSurfaceAsInvocation() {
        let input = "<command-args>just the args</command-args>"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).invocation, "just the args")
    }

    // MARK: - Output mirror

    func testOutputRowIsUnwrapped() {
        let record = ClaudeLocalCommandParser.parse(renameOutput)
        XCTAssertNil(record.invocation)
        XCTAssertEqual(record.output, "Session renamed to: cc-misc")
        XCTAssertEqual(record.displayLines, ["Session renamed to: cc-misc"])
    }

    func testBlankOutputRowRendersNothing() {
        // `/clear` mirrors an empty stdout; nothing to show.
        let record = ClaudeLocalCommandParser.parse("<local-command-stdout></local-command-stdout>")
        XCTAssertEqual(record, ClaudeLocalCommandRecord(invocation: nil, output: nil))
        XCTAssertTrue(record.displayLines.isEmpty)
    }

    func testStderrRowIsUnwrapped() {
        let input = "<local-command-stderr>Unknown model: foo</local-command-stderr>"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).output, "Unknown model: foo")
    }

    func testMultilineOutputKeepsInnerNewlines() {
        let input = "<local-command-stdout>Reloaded plugins:\n  a\n  b\n</local-command-stdout>"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).output, "Reloaded plugins:\n  a\n  b")
    }

    func testMultipleOutputBlocksAreJoinedInOrder() {
        let input = "<local-command-stdout>out</local-command-stdout><local-command-stderr>err</local-command-stderr>"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).output, "out\nerr")
    }

    func testUnclosedOutputTagKeepsTheRest() {
        let input = "<local-command-stdout>partial line"
        XCTAssertEqual(ClaudeLocalCommandParser.parse(input).output, "partial line")
    }

    // MARK: - Fallbacks

    func testPlainTextRowFallsBackToOutput() {
        XCTAssertEqual(ClaudeLocalCommandParser.parse("  Reloaded 3 plugins \n").output, "Reloaded 3 plugins")
    }

    func testWhitespaceOnlyRowRendersNothing() {
        XCTAssertTrue(ClaudeLocalCommandParser.parse(" \n\t ").displayLines.isEmpty)
    }

    func testEchoAndOutputInOneRowKeepTranscriptOrder() {
        let record = ClaudeLocalCommandParser.parse(renameEcho + "\n" + renameOutput)
        XCTAssertEqual(record.displayLines, ["/rename cc-misc", "Session renamed to: cc-misc"])
    }

    func testFreeTextNextToTagsIsKeptAsOutput() {
        let input = "<command-name>/model</command-name> switched"
        let record = ClaudeLocalCommandParser.parse(input)
        XCTAssertEqual(record.invocation, "/model")
        XCTAssertEqual(record.output, "switched")
    }
}
