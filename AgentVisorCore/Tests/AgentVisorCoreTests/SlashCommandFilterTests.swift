import XCTest
@testable import AgentVisorCore

/// Filters and ranks the catalog by a query string (the text typed
/// after the leading slash). Mirrors claude-code's score weighting
/// without the Fuse.js dependency: exact > prefix > substring > description,
/// with a stable alphabetical tie-breaker.
final class SlashCommandFilterTests: XCTestCase {

    private static func cmd(_ name: String, _ aliases: [String] = [], _ description: String = "", isHidden: Bool = false) -> SlashCommand {
        SlashCommand(name: name, aliases: aliases, description: description, source: .builtin, isHidden: isHidden)
    }

    // MARK: - Scenario 1: empty query returns the catalog in default order

    func test_givenEmptyQuery_whenFiltered_thenAllVisibleCommandsReturnInAlphabeticalOrder() {
        // Given three commands
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("copy"), Self.cmd("clear"), Self.cmd("compact")
        ])
        // When filtered with an empty query
        let result = SlashCommandFilter.filter(query: "", catalog: catalog)
        // Then all three appear, alphabetical
        XCTAssertEqual(result.map { $0.name }, ["clear", "compact", "copy"])
    }

    // MARK: - Scenario 2: exact name match ranks top

    func test_givenQueryMatchingNameExactly_whenFiltered_thenExactMatchIsFirst() {
        // Given commands where one matches the query verbatim
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("clear-cache"),
            Self.cmd("clear"),
            Self.cmd("clearable"),
        ])
        // When filtered by "clear"
        let result = SlashCommandFilter.filter(query: "clear", catalog: catalog)
        // Then exact match ranks first
        XCTAssertEqual(result.first?.name, "clear")
    }

    // MARK: - Scenario 3: prefix matches alphabetize beneath exact

    func test_givenPrefixQuery_whenFiltered_thenAllPrefixMatchesAppearAlphabetically() {
        // Given several /co prefix matches
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("config"), Self.cmd("copy"), Self.cmd("compact"), Self.cmd("color")
        ])
        // When filtered by "co"
        let result = SlashCommandFilter.filter(query: "co", catalog: catalog)
        // Then all four are prefix matches and sort alphabetically
        XCTAssertEqual(result.map { $0.name }, ["color", "compact", "config", "copy"])
    }

    // MARK: - Scenario 4: alias matches rank below exact name but above prefix

    func test_givenQueryMatchingAliasExactly_whenFiltered_thenAliasOutranksPrefixButNotExactName() {
        // Given commands with name and an aliased "resume"
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("resume-snapshot"),       // prefix match on "resume"
            Self.cmd("continue", ["resume"]),  // alias-exact match on "resume"
        ])
        // When filtered by "resume"
        let result = SlashCommandFilter.filter(query: "resume", catalog: catalog)
        // Then the alias-exact match ranks before the name-prefix match
        XCTAssertEqual(result.map { $0.name }, ["continue", "resume-snapshot"])
    }

    // MARK: - Scenario 5: description-only matches rank below name/alias matches

    func test_givenQueryFoundOnlyInDescription_whenFiltered_thenDescriptionMatchRanksBelowNameMatches() {
        // Given a command whose description contains the query letters
        // even though its name does not
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("save-to-obsidian", [], "Quick-save knowledge to the wiki"),
            Self.cmd("color", [], "Set the prompt bar color"),
        ])
        // When filtered by "co" — both /color (name-prefix) and
        // /save-to-obsidian (description has "co" inside "color"?) might
        // match. Confirm name-prefix outranks description-only.
        let result = SlashCommandFilter.filter(query: "co", catalog: catalog)
        // Then /color is first
        XCTAssertEqual(result.first?.name, "color")
    }

    // MARK: - Scenario 6: no match returns empty

    func test_givenQueryWithNoMatches_whenFiltered_thenResultIsEmpty() {
        // Given a catalog of three commands
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("a"), Self.cmd("b"), Self.cmd("c")
        ])
        // When filtered by a non-matching string
        let result = SlashCommandFilter.filter(query: "doesnotexist", catalog: catalog)
        // Then the result is empty
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Scenario 7: hidden commands stay hidden on empty query

    func test_givenHiddenCommand_whenFilteredWithEmptyQuery_thenHiddenIsAbsent() {
        // Given a hidden command alongside a normal one
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("public-thing"),
            Self.cmd("internal-thing", isHidden: true),
        ])
        // When filtered with no query
        let result = SlashCommandFilter.filter(query: "", catalog: catalog)
        // Then only the public command appears
        XCTAssertEqual(result.map { $0.name }, ["public-thing"])
    }

    // MARK: - Scenario 8: hidden commands surface on direct name query

    func test_givenHiddenCommandQueriedByExactName_whenFiltered_thenItAppears() {
        // Given the same hidden command
        let catalog = SlashCommandCatalog(commands: [
            Self.cmd("internal-thing", isHidden: true),
        ])
        // When queried by exact name
        let result = SlashCommandFilter.filter(query: "internal-thing", catalog: catalog)
        // Then it surfaces (still callable, just not advertised)
        XCTAssertEqual(result.map { $0.name }, ["internal-thing"])
    }

    // MARK: - Scenario 9: case-insensitive matching

    func test_givenUppercaseQuery_whenFiltered_thenLowercaseNameStillMatches() {
        // Given a lowercase command
        let catalog = SlashCommandCatalog(commands: [Self.cmd("compact")])
        // When the user queries in uppercase
        let result = SlashCommandFilter.filter(query: "COMP", catalog: catalog)
        // Then the match still fires
        XCTAssertEqual(result.first?.name, "compact")
    }
}
