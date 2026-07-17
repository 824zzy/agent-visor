import XCTest
@testable import AgentVisorCore

final class InjectionTagParserTests: XCTestCase {

    // MARK: - Attachment extraction

    func testExtractsOpenedFilePath() {
        let input = """
        <ide_opened_file>The user opened the file /Users/me/foo.md in the IDE. This may or may not be related to the current task.</ide_opened_file>
        Okay, let's delete it.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Okay, let's delete it.")
        XCTAssertEqual(parsed.attachments, [.openedFile(path: "/Users/me/foo.md")])
    }

    func testOpenedFilePathAtEnd() {
        let input = """
        Please review this.
        <ide_opened_file>The user opened the file /tmp/bar.py in the IDE.</ide_opened_file>
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Please review this.")
        XCTAssertEqual(parsed.attachments, [.openedFile(path: "/tmp/bar.py")])
    }

    func testMultipleOpenedFilesPreserveOrder() {
        let input = """
        <ide_opened_file>The user opened the file /a.md in the IDE.</ide_opened_file>
        <ide_opened_file>The user opened the file /b.md in the IDE.</ide_opened_file>
        Look at both.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Look at both.")
        XCTAssertEqual(parsed.attachments, [
            .openedFile(path: "/a.md"),
            .openedFile(path: "/b.md"),
        ])
    }

    func testMalformedOpenedFileSkipsAttachment() {
        // Tag is present but doesn't match the "opened the file … in the IDE" shape.
        let input = """
        <ide_opened_file>Something unexpected here</ide_opened_file>
        Hello.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Hello.")
        // Empty-path attachment emitted so the tag is at least removed
        // (UI can filter empty paths out).
        XCTAssertEqual(parsed.attachments, [.openedFile(path: "")])
    }

    func testSelectionWithLineRange() {
        let input = """
        <ide_selection>The user selected the lines 12 to 34 of file /tmp/x.swift in the IDE.</ide_selection>
        Help me refactor.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Help me refactor.")
        XCTAssertEqual(parsed.attachments, [
            .selection(path: "/tmp/x.swift", startLine: 12, endLine: 34)
        ])
    }

    func testSelectionWithSingleLine() {
        let input = """
        <ide_selection>The user selected line 7 of file /tmp/y.go in the IDE.</ide_selection>
        what is this?
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "what is this?")
        XCTAssertEqual(parsed.attachments, [
            .selection(path: "/tmp/y.go", startLine: 7, endLine: 7)
        ])
    }

    // MARK: - Hidden tag stripping

    func testStripsSystemReminder() {
        let input = """
        <system-reminder>noise</system-reminder>
        Real message.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Real message.")
        XCTAssertEqual(parsed.attachments, [])
    }

    func testCommandTagsRenderNameAndArgs() {
        // The user's actual prompt is `<command-args>`; rendering the
        // bubble means joining `<command-name>` + `<command-args>` so the
        // chat panel mirrors what the user typed in the terminal.
        // `<command-message>` is a redundant duplicate of the name and
        // gets stripped.
        let input = """
        <command-message>compact</command-message>
        <command-name>/compact</command-name>
        <command-args>focus on api</command-args>
        Summarize please.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "/compact focus on api\nSummarize please.")
        XCTAssertEqual(parsed.attachments, [])
    }

    func testCommandTagsWithoutArgsKeepsName() {
        let input = """
        <command-message>grill-me</command-message>
        <command-name>/grill-me</command-name>
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "/grill-me")
    }

    func testCommandTagsWithArgsOnly() {
        // Defensive: claude-code shape may evolve. If only args are
        // present, render them as a normal message — better than empty.
        let input = "<command-args>just the args</command-args>"
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "just the args")
    }

    func testGrillMeMultiSentenceArgs() {
        // The exact shape from a /grill-me invocation in production. The
        // bubble must show the slash + args, not vanish.
        let input = """
        <command-message>grill-me</command-message>
        <command-name>/grill-me</command-name>
        <command-args>I just had a in person discussion with Yunyao. We need to update the doc.</command-args>
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(
            parsed.plainText,
            "/grill-me I just had a in person discussion with Yunyao. We need to update the doc."
        )
    }

    func testStripsLocalCommandStdout() {
        let input = """
        <local-command-stdout>total 42
        -rw-r--r--  1 me  staff  0 Jan  1 00:00 foo</local-command-stdout>
        Did you see the listing?
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Did you see the listing?")
    }

    func testStripsBashStdoutAndStderr() {
        let input = """
        <bash-stdout>hello</bash-stdout>
        <bash-stderr>oops</bash-stderr>
        was that ok?
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "was that ok?")
    }

    // MARK: - Mixed content

    func testCombinedTagsAndText() {
        let input = """
        <ide_opened_file>The user opened the file /home/me/notes.md in the IDE.</ide_opened_file>
        <system-reminder>internal</system-reminder>
        Please summarize the notes.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Please summarize the notes.")
        XCTAssertEqual(parsed.attachments, [.openedFile(path: "/home/me/notes.md")])
    }

    func testOnlyTagsLeavesEmptyText() {
        let input = """
        <ide_opened_file>The user opened the file /a.md in the IDE.</ide_opened_file>
        <system-reminder>noise</system-reminder>
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "")
        XCTAssertEqual(parsed.attachments, [.openedFile(path: "/a.md")])
    }

    func testNoTagsPassesThrough() {
        let input = "Just a regular user message."
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Just a regular user message.")
        XCTAssertEqual(parsed.attachments, [])
    }

    func testTrimsLeadingTrailingWhitespace() {
        let input = """


        Hello there.

        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Hello there.")
    }

    // MARK: - Edge cases

    func testUnclosedTagLeavesContentAlone() {
        // No close tag → don't touch it. Better to render slightly
        // wrong than to silently swallow user content.
        let input = "<ide_opened_file>incomplete"
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "<ide_opened_file>incomplete")
    }

    func testMultilineHiddenTagContent() {
        let input = """
        <system-reminder>
        line 1
        line 2
        line 3
        </system-reminder>
        Visible message.
        """
        let parsed = InjectionTagParser.parse(input)
        XCTAssertEqual(parsed.plainText, "Visible message.")
    }
}
