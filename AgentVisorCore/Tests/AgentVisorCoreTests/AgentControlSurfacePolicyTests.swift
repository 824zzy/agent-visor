import XCTest
@testable import AgentVisorCore

final class AgentControlSurfacePolicyTests: XCTestCase {
    func testCodexDesktopOwnedSessionFocusesCodexRatherThanComposer() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .ownerApp(host: .codexApp),
            lifecycle: .live
        )

        XCTAssertFalse(decision.allowsComposer)
        XCTAssertEqual(decision.primaryAction, .openOwnerApp)
        XCTAssertEqual(decision.primaryActionTitle, "Focus Codex")
        XCTAssertEqual(decision.headline, "Codex Desktop is the primary chat")
    }

    func testCodexDesktopApprovalMustBeApprovedInCodex() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .ownerApp(host: .codexApp),
            lifecycle: .waitingForApproval
        )

        XCTAssertFalse(decision.allowsComposer)
        XCTAssertEqual(decision.primaryAction, .approveInOwnerApp)
        XCTAssertEqual(decision.primaryActionTitle, "Approve in Codex")
        XCTAssertEqual(decision.headline, "Codex Desktop is waiting for approval")
    }

    func testAgentVisorOwnedCodexSessionAllowsComposer() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .agentVisorAppServer,
            lifecycle: .live
        )

        XCTAssertTrue(decision.allowsComposer)
        XCTAssertEqual(decision.primaryAction, .none)
        XCTAssertNil(decision.primaryActionTitle)
    }

    func testConnectedCodexDesktopSessionAllowsComposerInAgentVisor() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .ownerApp(host: .codexApp),
            lifecycle: .live,
            codexCapability: .connected
        )

        XCTAssertTrue(decision.allowsComposer)
        XCTAssertEqual(decision.primaryAction, .none)
        XCTAssertNil(decision.primaryActionTitle)
        XCTAssertEqual(decision.headline, "")
    }

    func testTerminalOwnedCodexSessionFocusesTerminalRatherThanOpeningCodexDesktop() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .terminal(host: .ghostty),
            lifecycle: .live
        )

        XCTAssertFalse(decision.allowsComposer)
        XCTAssertEqual(decision.primaryAction, .focusHost)
        XCTAssertEqual(decision.primaryActionTitle, "Focus Ghostty")
        XCTAssertEqual(decision.headline, "Ghostty is the primary chat")
    }
}
