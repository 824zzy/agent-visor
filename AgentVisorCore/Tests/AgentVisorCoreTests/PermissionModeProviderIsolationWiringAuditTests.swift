import XCTest

final class PermissionModeProviderIsolationWiringAuditTests: XCTestCase {
    func testSessionStateAndStoreEnforceTheSharedProviderDecision() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sessionStore = try source(root, "AgentVisor/Services/State/SessionStore.swift")

        // The SessionState half of this rule is covered by behaviour now, in
        // SessionStateBehaviourTests: every non-Claude provider gets no mode and no cycling, a
        // Claude session without a terminal cannot cycle, and a tmux session is never probed.
        // Those tests call the property, so they also prove which fields it passes to the policy.

        XCTAssertGreaterThanOrEqual(
            sessionStore.components(
                separatedBy: "PermissionModeSurfacePolicy.acceptsStateUpdates(for: session.agentID)"
            ).count - 1,
            2,
            "SessionStore must guard both live mode updates and conversation-metadata hydration."
        )
    }

    func testEveryModeSurfaceUsesTheProviderAwareDecision() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let windowChat = try source(root, "AgentVisor/UI/Window/WindowChatView.swift")
        let windowComposer = try source(root, "AgentVisor/UI/Window/WindowComposer.swift")
        let hover = try source(root, "AgentVisor/UI/Components/SessionDetailPopover.swift")

        XCTAssertTrue(windowChat.contains("permissionMode: session.permissionModeSurfaceDecision.displayMode"))
        XCTAssertTrue(windowChat.contains("permissionMode: next.permissionModeSurfaceDecision.displayMode"))
        // The status control and the composer shortcut must share one decision.
        XCTAssertTrue(windowChat.contains("session.permissionModeSurfaceDecision.canCycle"))
        XCTAssertTrue(windowComposer.contains("session.permissionModeSurfaceDecision.canCycle"))
        XCTAssertTrue(hover.contains("permissionMode: session.permissionModeSurfaceDecision.displayMode"))

        for contents in [windowChat, hover] {
            XCTAssertFalse(contents.contains("permissionMode: session.permissionMode,"))
        }
    }

    func testModeProbeAndKeystrokeDeliveryFailClosedOutsideClaude() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let windowChat = try source(root, "AgentVisor/UI/Window/WindowChatView.swift")
        let cycler = try source(root, "AgentVisor/Services/Navigation/PermissionModeCycler.swift")

        XCTAssertGreaterThanOrEqual(
            windowChat.components(separatedBy: "permissionModeSurfaceDecision.shouldProbe").count - 1,
            2,
            "Compact Chat must gate both timer creation and each live probe tick."
        )
        XCTAssertGreaterThanOrEqual(
            windowChat.components(separatedBy: "permissionModeSurfaceDecision.shouldProbe").count - 1,
            2,
            "Window Chat must gate both timer creation and each live probe tick."
        )
        XCTAssertTrue(
            cycler.contains("guard session.permissionModeSurfaceDecision.canCycle else { return false }"),
            "The terminal boundary must reject Pi even if a caller regresses."
        )
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
