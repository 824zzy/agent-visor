import XCTest
@testable import AgentVisorCore

final class PillClickNavigationPolicyTests: XCTestCase {
    func testStandardClickFocusesClaudeCodeTerminalSessionOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .terminal(host: .iterm2)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickFocusesCodexDesktopOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .ownerApp(host: .codexApp)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickKeepsCodexCLISessionInOriginalTerminal() {
        let action = PillClickNavigationPolicy.action(
            ownership: .terminal(host: .ghostty)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickFocusesCursorOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .ownerApp(host: .cursor)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickFocusesZedOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .opaqueHost(host: .zed)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickFocusesClaudeDesktopOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .opaqueHost(host: .claudeDesktop)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickFocusesUnknownOwnerOriginalHost() {
        let action = PillClickNavigationPolicy.action(
            ownership: .opaqueHost(host: nil)
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testStandardClickOpensAgentVisorOwnedSessionInAgentVisor() {
        let action = PillClickNavigationPolicy.action(
            ownership: .agentVisorAppServer
        )

        XCTAssertEqual(action, .openAgentVisor)
    }

    func testOptionClickForcesAgentVisorForClaudeCodeTerminal() {
        let action = PillClickNavigationPolicy.action(
            ownership: .terminal(host: .iterm2),
            modifierIntent: .forceAgentVisor
        )

        XCTAssertEqual(action, .openAgentVisor)
    }

    func testOptionClickOpensAgentVisorForCodexDesktopMirror() {
        let action = PillClickNavigationPolicy.action(
            ownership: .ownerApp(host: .codexApp),
            modifierIntent: .forceAgentVisor
        )

        XCTAssertEqual(action, .openAgentVisor)
    }

    func testOptionClickFallsBackToOriginalWhenAgentVisorDetailUnavailable() {
        let action = PillClickNavigationPolicy.action(
            ownership: .ownerApp(host: .cursor),
            modifierIntent: .forceAgentVisor,
            agentVisorDetailAvailable: false
        )

        XCTAssertEqual(action, .openOriginal)
    }

    func testClaudeCodeCLIMenuUsesAgentVisorAndTerminalActions() {
        let model = PillClickMenuModel.session(
            agentID: .claudeCode,
            ownership: .terminal(host: .iterm2)
        )

        XCTAssertEqual(model.openAgentVisorTitle, "Open in Agent Visor")
        XCTAssertEqual(model.openOriginalTitle, "Focus iTerm2")
        XCTAssertTrue(model.canOpenOriginal)
    }

    func testAgentVisorOwnedMenuDoesNotOfferOriginalHost() {
        let model = PillClickMenuModel.session(
            agentID: .codex,
            ownership: .agentVisorAppServer
        )

        XCTAssertFalse(model.canOpenOriginal)
    }

    func testCodexDesktopMenuLabelsOriginalAsFocusCodex() {
        let model = PillClickMenuModel.session(
            agentID: .codex,
            ownership: .ownerApp(host: .codexApp)
        )

        XCTAssertEqual(model.openOriginalTitle, "Focus Codex")
        XCTAssertTrue(model.canOpenOriginal)
    }

    func testOverflowMenuOnlyOffersWindowAndSettings() {
        let model = PillClickOverflowMenuModel.menu()

        XCTAssertEqual(model.openAgentVisorTitle, "Open Agent Visor")
        XCTAssertEqual(model.settingsTitle, "Pill Settings...")
    }
}
