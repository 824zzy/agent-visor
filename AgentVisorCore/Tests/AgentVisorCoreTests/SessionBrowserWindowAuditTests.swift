import XCTest

final class SessionBrowserWindowAuditTests: XCTestCase {
    func testMainWindowIsSearchFirstAndKeepsInspectorOnDemand() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let model = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowViewModel.swift"))
        let codexStore = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Agents/CodexThreadStore.swift"))
        let controller = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowController.swift"))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift"))
        let notifications = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Services/Notifications/ApprovalNotifier.swift"))
        let appDelegate = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/App/AppDelegate.swift"))

        XCTAssertFalse(
            split.contains("Text(\"Agent Sessions\")"),
            "The full browser should begin with its primary search task, not a hero title."
        )
        XCTAssertTrue(split.contains("TextField(\"Search all sessions\""))
        XCTAssertFalse(
            split.contains("summaryStrip"),
            "Aggregate state chips duplicate the section headers and should not consume command-bar space."
        )
        XCTAssertFalse(split.contains("SessionBrowserSummaryChip"))
        XCTAssertTrue(split.contains("viewModel.openOriginal"))
        XCTAssertTrue(split.contains("viewModel.inspectSession"))
        XCTAssertTrue(split.contains(".sheet("))
        XCTAssertFalse(split.contains("NavigationSplitView"))
        XCTAssertFalse(split.contains("SessionWorkspaceOverview"))
        XCTAssertFalse(split.contains("let session: SessionState?"))
        XCTAssertTrue(split.contains("ForEach(viewModel.browserListElements)"))
        XCTAssertFalse(split.contains("ForEach(viewModel.browserSelection.groups"))
        XCTAssertTrue(split.contains("displaySection: section ?? item.section"))
        XCTAssertTrue(split.contains("return displaySection.tint"))
        XCTAssertTrue(model.contains("SessionBrowserPolicy.select"))
        XCTAssertTrue(model.contains("SessionBrowserListPresentation.elements"))
        XCTAssertTrue(model.contains("CodexThreadStore.browsableThreadCandidates()"))
        XCTAssertTrue(model.contains(".cvCodexCatalogDidChange"))
        XCTAssertTrue(codexStore.contains("name: .cvCodexCatalogDidChange"))
        XCTAssertTrue(model.contains("func prepareForSessionBrowser()"))
        XCTAssertTrue(split.contains(".onChange(of: viewModel.searchFocusRequest)"))
        XCTAssertTrue(controller.contains("func showSessions()"))
        XCTAssertTrue(controller.contains("viewModel.prepareForSessionBrowser()"))
        XCTAssertTrue(settings.contains("windowViewModel.prepareForSessionBrowser()"))
        XCTAssertTrue(notifications.contains("openSessionInMainWindow(sessionId)"))
        XCTAssertTrue(appDelegate.contains("ensureMainWindowController().showSessions()"))
        XCTAssertTrue(appDelegate.contains("ensureMainWindowController().toggleSessions()"))
    }

    func testPointerHoverDoesNotDriveKeyboardCursor() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        XCTAssertFalse(split.contains("onHighlight: { viewModel.highlightSession(sessionId) }"))
        XCTAssertFalse(split.contains("if hovering { onHighlight() }"))
    }

    func testScrollingFollowsExplicitRevealRequestsOnly() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let model = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowViewModel.swift"))

        XCTAssertTrue(split.contains(".onChange(of: viewModel.browserScrollRequest)"))
        XCTAssertTrue(split.contains("proxy.scrollTo(request.sessionId)"))
        XCTAssertFalse(split.contains(".onChange(of: viewModel.highlightedSessionId)"))
        XCTAssertFalse(split.contains(".onChange(of: viewModel.keyboardCursorSessionId)"))
        XCTAssertFalse(split.contains("anchor: .center"))
        XCTAssertTrue(model.contains("SessionBrowserInteractionPolicy.reduce"))
        XCTAssertTrue(model.contains("browserScrollRequest"))
    }

    func testCompactCommandBarAndFooterTeachConfiguredGlobalShortcuts() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        XCTAssertTrue(split.contains("GlobalSessionShortcutManager.shared"))
        XCTAssertTrue(split.contains("SessionBrowserShortcutEducationPolicy.presentation("))
        XCTAssertTrue(split.contains("footerShortcutEducation"))
        XCTAssertTrue(split.contains("footerShortcutHint("))
        XCTAssertTrue(split.contains(".padding(.vertical, 12)"))
        XCTAssertFalse(split.contains("private var shortcutEducation:"))
        XCTAssertFalse(split.contains("Find a session, then return to the app that owns it."))
        XCTAssertFalse(split.contains("Codex history included"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
