import XCTest
@testable import AgentVisorCore

/// Parses YAML-ish frontmatter from a markdown file's leading `---` block,
/// matching claude-code's loadSkillsDir conventions. The parser is
/// permissive: missing fields default to empty, malformed YAML returns
/// nil (not a throw), and a missing description falls back to the first
/// body paragraph.
final class SlashCommandFrontmatterParserTests: XCTestCase {

    // MARK: - Scenario 1: frontmatter populates fields

    func test_givenFrontmatterWithNameAndDescription_whenParsed_thenFieldsArePopulated() {
        // Given a markdown file with name and description in frontmatter
        let md = """
        ---
        name: copy
        description: Copy Claude's last response to clipboard
        ---
        Body text here.
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then those fields are exposed verbatim
        XCTAssertEqual(cmd?.name, "copy")
        XCTAssertEqual(cmd?.description, "Copy Claude's last response to clipboard")
    }

    // MARK: - Scenario 2: description falls back to first body paragraph

    func test_givenFrontmatterWithoutDescription_whenParsed_thenDescriptionComesFromFirstBodyParagraph() {
        // Given a file with frontmatter naming the command but no description field
        let md = """
        ---
        name: standup-generator
        ---
        Generates a stand-up update from recent activity.

        Second paragraph not used.
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the description is the first body paragraph (single line, trimmed)
        XCTAssertEqual(cmd?.description, "Generates a stand-up update from recent activity.")
    }

    // MARK: - Scenario 3: aliases round-trip as an array

    func test_givenFrontmatterWithAliases_whenParsed_thenAliasesAreParsed() {
        // Given a file with two aliases declared inline
        let md = """
        ---
        name: continue
        aliases: [resume, c]
        description: Resume a previous conversation
        ---
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then both aliases are present in order
        XCTAssertEqual(cmd?.aliases, ["resume", "c"])
    }

    // MARK: - Scenario 4: no frontmatter at all

    func test_givenNoFrontmatterBlock_whenParsed_thenNameComesFromFallbackAndBodyBecomesDescription() {
        // Given a file with no frontmatter at all, only a body
        let md = "Just a paragraph describing what this command does."
        // When parsed with a fallback name (caller derives this from filename)
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "fallback-name")
        // Then the fallback name is used and the body becomes the description
        XCTAssertEqual(cmd?.name, "fallback-name")
        XCTAssertEqual(cmd?.description, "Just a paragraph describing what this command does.")
    }

    // MARK: - Scenario 5: hidden flag

    func test_givenFrontmatterWithIsHiddenTrue_whenParsed_thenCommandIsFlaggedHidden() {
        // Given a file flagged hidden
        let md = """
        ---
        name: internal-thing
        description: Not for normal display
        isHidden: true
        ---
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the hidden flag round-trips
        XCTAssertEqual(cmd?.isHidden, true)
    }

    // MARK: - Scenario 6: malformed frontmatter

    func test_givenFrontmatterStartedButNotClosed_whenParsed_thenReturnsNilRatherThanThrowing() {
        // Given a file with an opening --- but no closing one
        let md = """
        ---
        name: broken
        description: missing closing fence
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the parser returns nil (caller decides how to handle)
        XCTAssertNil(cmd)
    }

    // MARK: - Scenario 7: argument hint round-trip

    func test_givenFrontmatterWithArgumentHint_whenParsed_thenArgumentHintRoundTrips() {
        // Given a file with an argumentHint field
        let md = """
        ---
        name: copy
        description: Copy Claude's last response (or /copy N for the Nth-latest)
        argumentHint: N
        ---
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the hint is preserved
        XCTAssertEqual(cmd?.argumentHint, "N")
    }

    // MARK: - Scenario 7b: argNames round-trip

    func test_givenFrontmatterWithArgNames_whenParsed_thenArgNamesAreParsed() {
        // Given a prompt-style command with multiple named args
        let md = """
        ---
        name: review
        description: Review a PR
        argNames: [owner, repo, pr_number]
        ---
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then argNames preserves order
        XCTAssertEqual(cmd?.argNames, ["owner", "repo", "pr_number"])
    }

    // MARK: - Scenario: quoted string values

    func test_givenFrontmatterWithQuotedDescription_whenParsed_thenQuotesAreStripped() {
        // Given a description wrapped in double quotes (common YAML pattern)
        let md = """
        ---
        name: color
        description: "Set the prompt bar color for this session"
        ---
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the outer quotes are removed and the inner value is preserved
        XCTAssertEqual(cmd?.description, "Set the prompt bar color for this session")
    }

    // MARK: - Scenario: blank lines between frontmatter and body

    func test_givenBlankLinesBeforeBodyParagraph_whenDescriptionFallback_thenFirstNonBlankParagraphIsUsed() {
        // Given frontmatter, then blank lines, then a description paragraph
        let md = """
        ---
        name: thing
        ---


        First real paragraph here.

        Second paragraph.
        """
        // When parsed
        let cmd = SlashCommandFrontmatterParser.parse(markdown: md, fallbackName: "ignored")
        // Then the leading blank lines are skipped and the first real paragraph wins
        XCTAssertEqual(cmd?.description, "First real paragraph here.")
    }
}
