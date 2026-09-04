import XCTest
@testable import AgentVisorCore

final class SlashCommandBuiltinsTests: XCTestCase {

    private var commandsByName: [String: SlashCommand] {
        Dictionary(uniqueKeysWithValues: SlashCommandBuiltins.all.map { ($0.name, $0) })
    }

    func testClaude237CatalogContainsConfirmedLocalCommands() {
        let commands = commandsByName

        XCTAssertEqual(commands["branch"]?.description, "Create a branch of the current conversation at this point")
        XCTAssertEqual(commands["branch"]?.argumentHint, "[name]")
        XCTAssertEqual(commands["fork"]?.description, "Copy this conversation into a new background session and keep working here")
        XCTAssertEqual(commands["fork"]?.argumentHint, "[prompt]")
        XCTAssertEqual(commands["loop"]?.aliases, ["proactive"])
        XCTAssertEqual(commands["loop"]?.description, "Run a prompt or slash command on a recurring interval (e.g. /loop 5m /foo, defaults to 10m)")
        XCTAssertEqual(commands["plugin"]?.aliases, ["plugins", "marketplace"])
        XCTAssertEqual(commands["plugin"]?.description, "Manage Claude Code plugins")
        XCTAssertEqual(commands["run"]?.description, "Launch this project’s app to see your change working")
        XCTAssertEqual(commands["stop"]?.description, "Stop this background session; transcript and worktree are kept")
        XCTAssertEqual(commands["tasks"]?.aliases, ["bashes"])
        XCTAssertEqual(commands["tasks"]?.description, "View and manage everything running in the background")
        XCTAssertEqual(commands["claude-api"]?.description, "Build and debug apps that use the Claude API")
    }

    func testClaude237CatalogUsesConfirmedAliasesAndDescriptions() {
        let commands = commandsByName

        XCTAssertEqual(commands["btw"]?.description, "Ask a quick side question without interrupting the main conversation")
        XCTAssertEqual(commands["bug"]?.aliases, ["share"])
        XCTAssertEqual(commands["bug"]?.description, "Report a bug or share your conversation")
        XCTAssertEqual(commands["clear"]?.aliases, ["reset", "new"])
        XCTAssertEqual(commands["clear"]?.description, "Start a new session with empty context; previous session stays on disk (resumable with /resume)")
        XCTAssertEqual(commands["config"]?.aliases, ["settings"])
        XCTAssertEqual(commands["config"]?.description, "Open settings")
        XCTAssertEqual(commands["feedback"]?.description, "Send feedback to Anthropic or report a bug")
        XCTAssertEqual(commands["permissions"]?.aliases, ["allowed-tools"])
        XCTAssertEqual(commands["permissions"]?.description, "Manage allow and deny tool permission rules")
        XCTAssertEqual(commands["release-notes"]?.description, "View release notes")
        XCTAssertEqual(commands["rename"]?.aliases, ["name"])
        XCTAssertEqual(commands["rename"]?.description, "Rename the current conversation")
    }

    func testClaude237CatalogExcludesNonSessionAndGatedCandidates() {
        let commands = commandsByName

        for excluded in [
            "auto-mode-setup", "usage-credits", "import", "artifacts", "chrome",
            "design", "teleport", "workflows", "team-onboarding", "powerup",
            "sessions", "streams", "tmp"
        ] {
            XCTAssertNil(commands[excluded], "Unexpected excluded slash command /\(excluded)")
        }
    }
}
