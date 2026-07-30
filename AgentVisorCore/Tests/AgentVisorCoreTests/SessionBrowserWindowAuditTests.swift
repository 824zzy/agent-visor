import XCTest

final class SessionBrowserWindowAuditTests: XCTestCase {
    func testMainWindowIsSearchFirstAndEntersChatWithoutAModal() throws {
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
        XCTAssertTrue(split.contains("viewModel.activateSession"))
        XCTAssertTrue(split.contains("viewModel.mode == .chat"))
        XCTAssertTrue(split.contains("SessionChatWorkspace("))
        XCTAssertFalse(split.contains("viewModel.inspectSession"))
        XCTAssertFalse(split.contains(".sheet("))
        XCTAssertFalse(split.contains("NavigationSplitView"))
        XCTAssertFalse(split.contains("SessionWorkspaceOverview"))
        XCTAssertFalse(split.contains("let session: SessionState?"))
        XCTAssertTrue(split.contains("ForEach(viewModel.browserListElements)"))
        XCTAssertFalse(split.contains("ForEach(viewModel.browserSelection.groups"))
        XCTAssertTrue(split.contains("displaySection: section ?? item.section"))
        XCTAssertTrue(split.contains("return displaySection.tint"))
        XCTAssertTrue(model.contains("SessionBrowserPolicy.select"))
        XCTAssertTrue(model.contains("SessionBrowserListPresentation.elements"))
        XCTAssertTrue(model.contains("SessionBrowserPrimaryActionPolicy.action"))
        XCTAssertTrue(model.contains("func enterChat("))
        XCTAssertTrue(model.contains("func leaveChat()"))
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

    func testRowsAndKeyboardUseStableChatFirstActions() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let model = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowViewModel.swift"))

        XCTAssertFalse(split.contains("SessionBrowserActionSelector.shared"))
        XCTAssertTrue(split.contains("viewModel.activateSession(\n                        sessionId\n                    )"))
        XCTAssertTrue(split.contains("viewModel.activateKeyboardCursor()"))
        XCTAssertTrue(split.contains("viewModel.activateKeyboardCursor(alternate: true)"))
        XCTAssertTrue(split.contains("modifiers == .shift"))
        XCTAssertFalse(model.contains("defaultAction: SessionBrowserDefaultAction"))
        XCTAssertTrue(model.contains("alternate: Bool = false"))
    }

    func testSessionsDoNotExposeADestinationPreferenceThatCanInvertControls() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Core/Settings.swift"))
        let settingsView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift"))
        let selector = root
            .appendingPathComponent("AgentVisor/Core/SessionBrowserActionSelector.swift")

        XCTAssertFalse(settings.contains("sessionBrowserDefaultAction"))
        XCTAssertFalse(settingsView.contains("Default session action"))
        XCTAssertFalse(settingsView.contains("SessionBrowserActionSelector"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selector.path))
    }

    func testCoreRowActionPolicyCannotBeOverriddenByAStoredDestination() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let policy = try String(contentsOf: root
            .appendingPathComponent("AgentVisorCore/Sources/AgentVisorCore/SessionBrowserPrimaryActionPolicy.swift"))

        XCTAssertFalse(policy.contains("SessionBrowserDefaultAction"))
        XCTAssertFalse(policy.contains("defaultAction:"))
        XCTAssertTrue(policy.contains("alternate: Bool = false"))
    }

    func testRowOwnsChatDisclosureAndOwnerActionHasADisjointTarget() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        XCTAssertTrue(split.contains("Button(action: onActivate)"))
        XCTAssertTrue(split.contains("if item.canEnterChat {\n                        chatDisclosureChevron"))
        XCTAssertTrue(split.contains("private var chatDisclosureChevron: some View"))
        XCTAssertTrue(split.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(split.contains("SessionBrowserOwnerAction("))
        XCTAssertTrue(split.contains("onOpenOriginal: { viewModel.openOriginal(sessionId) }"))
        XCTAssertTrue(split.contains("action: onOpenOriginal"))
        XCTAssertTrue(split.contains("fullTitle: \"Open in \\(item.ownerName)\""))
        XCTAssertTrue(split.contains(".frame(width: 138, alignment: .trailing)"))
        XCTAssertFalse(split.contains("SessionBrowserChatDisclosure"))
        XCTAssertFalse(split.contains("title: \"Enter Chat\""))
        XCTAssertFalse(split.contains("prominent: true"))
        XCTAssertTrue(split.contains("keyboardHint(keys: \"↩\", label: footerLabel"))
        XCTAssertTrue(split.contains("keyboardHint(keys: \"⇧↩\", label: footerLabel"))
        XCTAssertFalse(split.contains("keyboardHint(keys: \"⌥↩\""))
        XCTAssertFalse(split.contains("Inspect session"))
    }

    func testFooterActionCopyIsProviderNeutralWhileRowsKeepExactOwners() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        guard let start = split.range(of: "private func footerLabel")?.lowerBound,
              let end = split.range(of: "private func keyboardHint", range: start..<split.endIndex)?.lowerBound else {
            return XCTFail("Could not isolate footerLabel.")
        }
        let footerLabel = String(split[start..<end])
        XCTAssertTrue(footerLabel.contains("SessionBrowserPrimaryActionPolicy.footerLabel"))
        XCTAssertFalse(footerLabel.contains("ownerName"))
        XCTAssertTrue(split.contains("fullTitle: \"Open in \\(item.ownerName)\""))
    }

    func testBackKeepsTheMountedBrowserStateInsteadOfReconstructingIt() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let model = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowViewModel.swift"))

        XCTAssertTrue(split.contains("sessionsBrowser\n                .opacity(viewModel.mode == .sessions ? 1 : 0)"))
        XCTAssertTrue(split.contains("onBack: { viewModel.leaveChat() }"))
        let start = try XCTUnwrap(model.range(of: "func leaveChat()"))
        let end = try XCTUnwrap(model.range(of: "func openOriginal(", range: start.upperBound..<model.endIndex))
        let leaveChat = String(model[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(leaveChat.contains("searchQuery"))
        XCTAssertFalse(leaveChat.contains("keyboardCursorSessionId"))
        XCTAssertFalse(leaveChat.contains("browserScrollRequest"))
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
