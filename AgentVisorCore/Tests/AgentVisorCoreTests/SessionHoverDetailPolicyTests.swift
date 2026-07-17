import XCTest
@testable import AgentVisorCore

final class SessionHoverDetailPolicyTests: XCTestCase {
    func testCodexLatestTurnDetailsArePresentedForHoverInspection() {
        let presentation = SessionHoverDetailPolicy.presentation(
            phase: .ready,
            sourceDisplayName: "Codex Desktop",
            modelDisplayName: "GPT-5.5",
            effortLevel: "xhigh",
            permissionMode: nil,
            codexApprovalPolicy: "never",
            codexSandboxPolicyType: "danger-full-access",
            contextTokens: 244_000,
            contextWindowTokens: 258_000
        )

        XCTAssertEqual(presentation.statusTitle, "Ready")
        XCTAssertEqual(presentation.runtimeItems, ["Codex Desktop", "GPT-5.5"])
        XCTAssertEqual(
            presentation.detailRows,
            [
                SessionHoverDetailRow(label: "Reasoning", value: "XHigh"),
                SessionHoverDetailRow(label: "Access", value: "Full access · Never ask"),
            ]
        )
        XCTAssertEqual(
            presentation.context,
            SessionHoverContextPresentation(
                usedLabel: "244k",
                windowLabel: "258k",
                percentage: 95
            )
        )
    }

    func testUnavailableMetadataIsOmittedAndClaudeModeRemainsSourceSpecific() {
        let presentation = SessionHoverDetailPolicy.presentation(
            phase: .working,
            sourceDisplayName: "Claude Code · iTerm2",
            modelDisplayName: nil,
            effortLevel: nil,
            permissionMode: "plan",
            codexApprovalPolicy: nil,
            codexSandboxPolicyType: nil,
            contextTokens: 0,
            contextWindowTokens: 0
        )

        XCTAssertEqual(presentation.statusTitle, "Working")
        XCTAssertEqual(presentation.runtimeItems, ["Claude Code · iTerm2"])
        XCTAssertEqual(
            presentation.detailRows,
            [SessionHoverDetailRow(label: "Mode", value: "Plan")]
        )
        XCTAssertNil(presentation.context)
    }

    func testEnabledPillShortcutIsPresentedAsHoverGuidance() {
        let presentation = SessionHoverDetailPolicy.presentation(
            phase: .ready,
            sourceDisplayName: "Codex Desktop",
            modelDisplayName: "GPT-5.5",
            effortLevel: nil,
            permissionMode: nil,
            codexApprovalPolicy: nil,
            codexSandboxPolicyType: nil,
            contextTokens: 0,
            contextWindowTokens: 0,
            shortcutModifierFamily: .optionCommand,
            shortcutPosition: 3
        )

        XCTAssertEqual(presentation.shortcutLabel, "⌥⌘3")
    }

    func testCodexAppSourceIsNamedCodexDesktop() {
        XCTAssertEqual(
            SessionHoverDetailPolicy.sourceDisplayName(
                agentID: .codex,
                terminalHost: .codexApp
            ),
            "Codex Desktop"
        )
    }

    func testSourceNamePreservesAgentAndOwningHostWithoutDuplication() {
        XCTAssertEqual(
            SessionHoverDetailPolicy.sourceDisplayName(
                agentID: .claudeCode,
                terminalHost: .iterm2
            ),
            "Claude Code · iTerm2"
        )
        XCTAssertEqual(
            SessionHoverDetailPolicy.sourceDisplayName(
                agentID: .cursor,
                terminalHost: .cursor
            ),
            "Cursor"
        )
        XCTAssertEqual(
            SessionHoverDetailPolicy.sourceDisplayName(
                agentID: .auggie,
                terminalHost: nil
            ),
            "Auggie"
        )
    }
}
