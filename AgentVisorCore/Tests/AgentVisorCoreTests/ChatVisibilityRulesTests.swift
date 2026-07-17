//
//  ChatVisibilityRulesTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ChatVisibilityRulesTests: XCTestCase {
    func testDefaultsShowEverything() {
        let r = ChatVisibilityRules.defaults
        let allKinds: [ChatItemKind] = [
            .userMessage, .assistantMessage, .thinking, .interrupted,
            .turnDuration, .recap, .compactBoundary, .localCommandOutput,
            .toolCall(.read), .toolCall(.edit), .toolCall(.write),
            .toolCall(.bash), .toolCall(.grep), .toolCall(.glob),
            .toolCall(.todoWrite), .toolCall(.task), .toolCall(.webFetch),
            .toolCall(.webSearch), .toolCall(.askUserQuestion),
            .toolCall(.bashOutput), .toolCall(.killShell),
            .toolCall(.exitPlanMode), .toolCall(.enterPlanMode),
            .toolCall(.mcp(server: "any", tool: "any")),
            .toolCall(.generic(name: "Custom")),
        ]
        for kind in allKinds {
            XCTAssertTrue(
                ChatVisibilityFilter.shouldShow(kind, rules: r),
                "default should show \(kind)"
            )
        }
    }

    func testHidingBashHidesOnlyBash() {
        var r = ChatVisibilityRules.defaults
        r.showBash = false
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(.bash), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.read), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.assistantMessage, rules: r))
    }

    func testHidingReadDoesNotHideEdit() {
        var r = ChatVisibilityRules.defaults
        r.showRead = false
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(.read), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.edit), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.write), rules: r))
    }

    func testHidingThinkingPreservesAssistantText() {
        var r = ChatVisibilityRules.defaults
        r.showThinking = false
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.thinking, rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.assistantMessage, rules: r))
    }

    func testPlanModeToggleCoversBothCases() {
        var r = ChatVisibilityRules.defaults
        r.showPlanMode = false
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(.enterPlanMode), rules: r))
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(.exitPlanMode), rules: r))
    }

    func testMCPToolsRoutedThroughShowMCP() {
        var r = ChatVisibilityRules.defaults
        r.showMCP = false
        let mcp = CanonicalTool.mcp(server: "atlassian-jira", tool: "jira_get_issue")
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(mcp), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.bash), rules: r))
    }

    func testGenericToolsRoutedThroughShowOtherTools() {
        var r = ChatVisibilityRules.defaults
        r.showOtherTools = false
        let custom = CanonicalTool.generic(name: "WeirdCustomTool")
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(custom), rules: r))
        // Known tools must remain unaffected by the catch-all toggle.
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.bash), rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.toolCall(.read), rules: r))
    }

    func testHidingAllToolsLeavesProseVisible() {
        var r = ChatVisibilityRules.defaults
        r.showBash = false
        r.showRead = false
        r.showWrite = false
        r.showEdit = false
        r.showGrep = false
        r.showGlob = false
        r.showWebFetch = false
        r.showWebSearch = false
        r.showTodoWrite = false
        r.showTask = false
        r.showAskUserQuestion = false
        r.showBashOutput = false
        r.showKillShell = false
        r.showPlanMode = false
        r.showMCP = false
        r.showOtherTools = false
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.userMessage, rules: r))
        XCTAssertTrue(ChatVisibilityFilter.shouldShow(.assistantMessage, rules: r))
        XCTAssertFalse(ChatVisibilityFilter.shouldShow(.toolCall(.bash), rules: r))
    }

    func testCodableRoundTripPreservesAllFields() throws {
        var r = ChatVisibilityRules.defaults
        r.showBash = false
        r.showThinking = false
        r.showMCP = false
        r.showWebFetch = false

        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(ChatVisibilityRules.self, from: data)
        XCTAssertEqual(r, decoded)
    }

    func testCodableForwardCompatFillsMissingKeysWithDefaults() throws {
        // Simulate an older on-disk blob that's missing newer keys
        // (e.g., showMCP added in a later build). The decoder must
        // use defaults for anything absent so existing toggles aren't
        // reset.
        let partial: [String: Bool] = [
            "showBash": false,
            "showRead": false,
        ]
        let data = try JSONEncoder().encode(partial)
        let decoded = try JSONDecoder().decode(ChatVisibilityRules.self, from: data)
        XCTAssertFalse(decoded.showBash)
        XCTAssertFalse(decoded.showRead)
        // Missing keys take the default (true).
        XCTAssertTrue(decoded.showMCP)
        XCTAssertTrue(decoded.showWebFetch)
        XCTAssertTrue(decoded.showAssistantMessage)
    }

    func testEqualityIsValueBased() {
        let a = ChatVisibilityRules.defaults
        var b = ChatVisibilityRules.defaults
        XCTAssertEqual(a, b)
        b.showBash = false
        XCTAssertNotEqual(a, b)
    }
}
