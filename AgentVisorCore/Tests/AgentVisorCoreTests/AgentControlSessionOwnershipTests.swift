import XCTest
@testable import AgentVisorCore

/// Who owns a running session, and what each surface may do about it.
///
/// The ownership rule used to live in a SwiftUI view file, while the type it returns and the
/// policy that reads it lived here. No test in this package named `AgentControlSessionOwnership`
/// before this file, so five branches of routing went unchecked.
final class AgentControlSessionOwnershipTests: XCTestCase {
    private func session(
        origin: SessionOrigin,
        agentID: AgentID = .claudeCode,
        terminalHost: TerminalHost? = nil
    ) -> SessionState {
        var state = SessionStateFixture.make(agentID: agentID, terminalHost: terminalHost)
        state.origin = origin
        return state
    }

    func testVisorSpawnedSessionsBelongToOurAppServer() {
        XCTAssertEqual(AgentControlSessionOwnership.of(session(origin: .visorSpawned)), .agentVisorAppServer)
        XCTAssertEqual(AgentControlSessionOwnership.of(session(origin: .codexAppServer)), .agentVisorAppServer)
    }

    func testTerminalSessionsKeepTheirHost() {
        let owned = AgentControlSessionOwnership.of(
            session(origin: .terminal, terminalHost: .ghostty)
        )
        XCTAssertEqual(owned, .terminal(host: .ghostty))
    }

    func testTerminalSessionWithoutAKnownHostIsStillATerminal() {
        XCTAssertEqual(AgentControlSessionOwnership.of(session(origin: .terminal)), .terminal(host: nil))
    }

    func testCursorObservedSessionsFallBackToCursor() {
        XCTAssertEqual(
            AgentControlSessionOwnership.of(session(origin: .cursorObserved)),
            .ownerApp(host: .cursor),
            "A Cursor thread we only observe still belongs to Cursor, even with no host recorded."
        )
    }

    func testCursorObservedSessionKeepsARealHost() {
        let owned = AgentControlSessionOwnership.of(
            session(origin: .cursorObserved, terminalHost: .zed)
        )
        XCTAssertEqual(owned, .ownerApp(host: .zed))
    }

    func testObservedCodexThreadBelongsToCodexApp() {
        for host in [TerminalHost?.none, .some(.unknown), .some(.codexApp)] {
            let owned = AgentControlSessionOwnership.of(
                session(origin: .observed, agentID: .codex, terminalHost: host)
            )
            XCTAssertEqual(
                owned,
                .ownerApp(host: .codexApp),
                "An observed Codex thread with no real host is driven from Codex.app."
            )
        }
    }

    func testObservedCodexThreadInARealTerminalKeepsThatTerminal() {
        let owned = AgentControlSessionOwnership.of(
            session(origin: .observed, agentID: .codex, terminalHost: .iterm2)
        )
        XCTAssertEqual(owned, .ownerApp(host: .iterm2))
    }

    func testOtherObservedSessionsAreOpaque() {
        let owned = AgentControlSessionOwnership.of(
            session(origin: .observed, agentID: .claudeCode, terminalHost: .zed)
        )
        XCTAssertEqual(
            owned,
            .opaqueHost(host: .zed),
            "We cannot drive a session we only read, so the surface must say so."
        )
    }

    // MARK: - What the surfaces do with it

    func testOurOwnSessionsAllowTheComposer() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .codex,
            ownership: .agentVisorAppServer,
            lifecycle: .live
        )
        XCTAssertTrue(decision.allowsComposer)
    }

    func testAnOpaqueSessionOffersNoComposer() {
        let decision = AgentControlSurfacePolicy.decision(
            agentID: .claudeCode,
            ownership: .opaqueHost(host: .zed),
            lifecycle: .live
        )
        XCTAssertFalse(
            decision.allowsComposer,
            "Typing into a session we only observe would go nowhere."
        )
    }
}
