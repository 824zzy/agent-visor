import XCTest
@testable import AgentVisorCore

/// Pulls the user-typed text out of claude-code's TUI input box, the
/// boxed region with `╭ │ ╰` borders that holds the next-prompt buffer.
/// Used by the clear-before-send path: agent-visor reads the AX text
/// of Ghostty's terminal pane to find out how many chars to backspace
/// before injecting the next prompt, so the previous (canceled,
/// restored, or otherwise leftover) content doesn't get concatenated
/// onto the new one.
///
/// Contract:
///   nil → no input box found in the buffer
///   ""  → input box found and empty (no clearing needed)
///   "x" → input box found with content "x" (caller should send N backspaces)
final class TUIInputBoxParserTests: XCTestCase {

    // MARK: - Scenario 1: empty scrollback

    func test_givenEmptyScrollback_whenParsed_thenReturnsNil() {
        // Given no scrollback text
        let scrollback = ""
        // When parsed for the current input box
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then nothing to extract
        XCTAssertNil(input)
    }

    // MARK: - Scenario 2: scrollback without an input box

    func test_givenScrollbackWithNoInputBox_whenParsed_thenReturnsNil() {
        // Given normal scrollback lines but no boxed input region
        let scrollback = """
        $ ls
        README.md
        ● Hi there, what can I help with?
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then nil — clearing is unnecessary
        XCTAssertNil(input)
    }

    // MARK: - Scenario 3: empty input box returns ""

    func test_givenInputBoxWithOnlyPromptArrow_whenParsed_thenReturnsEmptyString() {
        // Given a freshly-rendered input box with only the `>` prompt
        // prefix and trailing pad whitespace
        let scrollback = """
        ● Some assistant output.

        ╭───────────────────────────────────────╮
        │ >                                     │
        ╰───────────────────────────────────────╯
          ⏵⏵ accept edits on
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then the empty string: the box exists but is content-empty,
        // so the caller knows it doesn't need to send backspaces.
        XCTAssertEqual(input, "")
    }

    // MARK: - Scenario 4: single-line typed input

    func test_givenInputBoxWithSingleLineText_whenParsed_thenReturnsThatText() {
        // Given a user-typed single line inside the input box
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ > hello world                         │
        ╰───────────────────────────────────────╯
          ⏵⏵ auto mode on
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then the typed text is returned without the prompt prefix
        // or padding whitespace
        XCTAssertEqual(input, "hello world")
    }

    // MARK: - Scenario 5: multi-line input (continuation lines)

    func test_givenInputBoxWithMultiLineText_whenParsed_thenReturnsAllLinesJoinedByNewlines() {
        // Given a multi-line input where continuation lines lack the
        // `>` prefix and instead start with `│ ` plus indentation
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ > line one                            │
        │   line two                            │
        │   line three                          │
        ╰───────────────────────────────────────╯
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then the three logical lines are joined by `\n`. The caller
        // will count chars (including the newlines) to compute the
        // backspace count.
        XCTAssertEqual(input, "line one\nline two\nline three")
    }

    // MARK: - Scenario 6: multiple boxes — last one wins

    func test_givenMultipleInputBoxes_whenParsed_thenReturnsContentOfLastBox() {
        // Given two boxes — the first is old scrollback, the second
        // is the active prompt at the bottom
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ > old query                           │
        ╰───────────────────────────────────────╯

        Some intervening assistant output here.

        ╭───────────────────────────────────────╮
        │ > new query                           │
        ╰───────────────────────────────────────╯
          ⏵⏵ accept edits on
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then the LAST box (the current active input) is returned
        XCTAssertEqual(input, "new query")
    }

    // MARK: - Scenario 7: status line below the box does not leak

    func test_givenInputBoxFollowedByStatusLine_whenParsed_thenStatusLineIsNotIncluded() {
        // Given a typical full TUI bottom: input box + mode chip line
        // + usage line
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ > what is the answer                  │
        ╰───────────────────────────────────────╯
          ⏵⏵ accept edits on            sonnet 4.6
          context: 33%                  cost: $0.42
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then only the boxed content is returned
        XCTAssertEqual(input, "what is the answer")
    }

    // MARK: - Scenario 8: box with internal padding chars only

    func test_givenInputBoxWithOnlyWhitespaceContent_whenParsed_thenReturnsEmptyString() {
        // Given a box whose content row is `│` whitespace `│` with no
        // prompt arrow at all (theoretical edge case)
        let scrollback = """
        ╭───────────────────────────────────────╮
        │                                       │
        ╰───────────────────────────────────────╯
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then empty string — no real text inside, no backspaces needed
        XCTAssertEqual(input, "")
    }

    // MARK: - Scenario 9: text with leading/trailing whitespace inside box

    func test_givenInputBoxWithExtraInternalPadding_whenParsed_thenInternalLeadingSpacesArePreserved() {
        // Given text typed with leading spaces (uncommon but possible).
        // The right-edge padding is trimmed, but a user-typed leading
        // space stays because it's between the prompt arrow's whitespace
        // and the content — we can't distinguish "extra-indented
        // continuation" from "user typed a leading space," so the parser
        // takes a conservative stance and preserves it. The downstream
        // backspace count works either way.
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ >   text with leading spaces          │
        ╰───────────────────────────────────────╯
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then we get the text after stripping just one space after the
        // `>` (the canonical separator); any additional leading spaces
        // are treated as part of the user content
        XCTAssertEqual(input, "  text with leading spaces")
    }

    // MARK: - Scenario 10: malformed box (open but never closed)

    func test_givenInputBoxOpenButNeverClosed_whenParsed_thenReturnsNil() {
        // Given a `╭` line without a matching `╰` (truncated buffer)
        let scrollback = """
        ╭───────────────────────────────────────╮
        │ > partial content                     │
        """
        // When parsed
        let input = TUIInputBoxParser.currentInput(in: scrollback)
        // Then nil — we can't trust an unclosed box (might be old/cached)
        XCTAssertNil(input)
    }
}
