import XCTest

final class SessionHoverDetailWiringAuditTests: XCTestCase {
    func testPillHoverCardUsesSourceAwareLatestTurnPresentation() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Components/SessionDetailPopover.swift"))

        XCTAssertTrue(source.contains("SessionHoverDetailPolicy.presentation("))
        XCTAssertTrue(source.contains("SessionHoverDetailPolicy.sourceDisplayName("))
        XCTAssertTrue(source.contains("effortLevel: session.effortLevel"))
        XCTAssertTrue(source.contains("codexApprovalPolicy: session.conversationInfo.lastCodexApprovalPolicy"))
        XCTAssertTrue(source.contains("codexSandboxPolicyType: session.conversationInfo.lastCodexSandboxPolicyType"))
        XCTAssertTrue(source.contains(".frame(width: 300"))
    }

    func testPillHoverCardOwnsAnOpaquePaletteMatchedSurface() throws {
        let source = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/UI/Components/SessionDetailPopover.swift"))

        let frameRange = try XCTUnwrap(source.range(of: ".frame(width: 300"))
        let surfaceRange = try XCTUnwrap(source.range(of: ".background(Catppuccin.base)"))

        XCTAssertLessThan(frameRange.lowerBound, surfaceRange.lowerBound)
        XCTAssertFalse(source.contains(".thinMaterial"))
        XCTAssertFalse(source.contains(".regularMaterial"))
        XCTAssertFalse(source.contains(".ultraThinMaterial"))
    }

    func testPiSurfacesDoNotUseClaudeContextWindowFallback() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Shared/ClaudeSettings.swift"))
        let surfacePaths = [
            "AgentVisor/UI/Components/SessionDetailPopover.swift",
            "AgentVisor/UI/Views/ChatView.swift",
            "AgentVisor/UI/Window/WindowChatView.swift",
        ]

        XCTAssertTrue(settings.contains("if session.agentID == .pi { return 0 }"))
        for path in surfacePaths {
            let source = try String(contentsOf: root.appendingPathComponent(path))
            XCTAssertTrue(source.contains("ModelContextWindow.tokens(for: session)"), path)
        }
    }

    func testPillHoverCardShowsTheConfiguredShortcutForItsRenderedSlot() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let popover = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/SessionDetailPopover.swift"))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Components/NotchSideContent.swift"))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Events/GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(popover.contains("shortcutModifierFamily: shortcutModifierFamily"))
        XCTAssertTrue(popover.contains("shortcutPosition: shortcutPosition"))
        XCTAssertTrue(popover.contains("presentation.shortcutLabel"))
        XCTAssertTrue(popover.contains("Text(\"Open directly\")"))
        XCTAssertTrue(sideContent.contains("shortcutPosition: pill.shortcutPosition"))
        XCTAssertTrue(sideContent.contains("shortcutModifierFamily: sessionShortcutManager.family"))
        XCTAssertTrue(manager.contains("@Published private(set) var family"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
