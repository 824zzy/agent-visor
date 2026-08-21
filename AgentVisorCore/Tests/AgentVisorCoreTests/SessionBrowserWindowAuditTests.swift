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

    func testRowsAndKeyboardUseStableSourceFirstActions() throws {
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

    func testRowNamesTheSourcePrimaryActionAndKeepsChatDisjoint() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        XCTAssertTrue(split.contains("Button(action: onActivate)"))
        XCTAssertTrue(split.contains("private var primaryDestinationLabel: some View"))
        XCTAssertTrue(split.contains("Label(\"Open in \\(item.ownerName)\", systemImage: \"arrow.up.forward.app\")"))
        XCTAssertTrue(split.contains("@State private var isPrimaryHovered = false"))
        XCTAssertTrue(split.contains(".background(primaryRowBackground)"))
        XCTAssertTrue(split.contains("ChatTheme.link : ChatTheme.secondary"))
        XCTAssertTrue(split.contains("if showsOwner, primaryAction != .openOriginal, item.ownerName != item.sourceName"))
        XCTAssertFalse(split.contains(".background(rowBackground)"))
        XCTAssertTrue(split.contains("SessionBrowserAccessoryAction("))
        XCTAssertTrue(split.contains("fullTitle: \"Open Chat\""))
        XCTAssertTrue(split.contains("action: onEnterChat"))
        XCTAssertTrue(split.contains("ChatTheme.link : ChatTheme.tertiary"))
        XCTAssertTrue(split.contains("onOpenOriginal: { viewModel.openOriginal(sessionId) }"))
        XCTAssertTrue(split.contains(".frame(width: 138, alignment: .leading)"))
        XCTAssertTrue(split.contains(".frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)"))
        XCTAssertTrue(split.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(split.contains("chatDisclosureChevron"))
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
        XCTAssertTrue(split.contains("Label(\"Open in \\(item.ownerName)\", systemImage: \"arrow.up.forward.app\")"))
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

    func testBrowserHandlesContentScaleShortcutsWithoutStealingGlobalModifierFamilies() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let start = try XCTUnwrap(split.range(of: "private func installKeyboardMonitor()"))
        let end = try XCTUnwrap(split.range(
            of: "private func removeKeyboardMonitor()",
            range: start.upperBound..<split.endIndex
        ))
        let handler = String(split[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(handler.contains("ContentFontScaleCommand.decode("))
        XCTAssertTrue(handler.contains("optionHeld: modifiers.contains(.option)"))
        XCTAssertTrue(handler.contains("controlHeld: modifiers.contains(.control)"))
        XCTAssertTrue(handler.contains("AppSettings.contentFontScale = command.apply("))
        XCTAssertTrue(handler.contains("step: AppSettings.contentFontScaleStep"))
        XCTAssertTrue(handler.contains("min: AppSettings.contentFontScaleMin"))
        XCTAssertTrue(handler.contains("max: AppSettings.contentFontScaleMax"))

        let scaleDecode = try XCTUnwrap(handler.range(of: "ContentFontScaleCommand.decode("))
        let sessionHotkey = try XCTUnwrap(handler.range(of: "SessionHotkeyMatcher.position("))
        XCTAssertLessThan(
            handler.distance(from: handler.startIndex, to: scaleDecode.lowerBound),
            handler.distance(from: handler.startIndex, to: sessionHotkey.lowerBound),
            "Content scaling should consume plain Cmd zoom gestures before numbered-session matching."
        )
    }

    func testEverySessionsBrowserTextRoleConsumesTheSharedContentScale() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let sharedScale = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Views/ChatView.swift"))

        XCTAssertTrue(sharedScale.contains("var contentFontScale: CGFloat"))
        XCTAssertTrue(sharedScale.contains("func contentScaledFont("))
        XCTAssertTrue(split.contains(".environment(\\.contentFontScale, CGFloat(contentFontScaleStorage))"))
        XCTAssertTrue(split.contains(".contentScaledFont(size: 14, weight: .semibold)"))
        XCTAssertTrue(split.contains(".contentScaledFont(size: 12)"))
        XCTAssertTrue(split.contains(".contentScaledFont(size: 10, weight: .medium)"))
        XCTAssertTrue(split.contains(".contentScaledFont(size: 11, weight: .semibold)"))

        let scaledRoleCount = split.components(separatedBy: ".contentScaledFont(").count - 1
        XCTAssertGreaterThanOrEqual(
            scaledRoleCount,
            24,
            "Search, health, sections, rows, chips, actions, empty states, and footer should all scale."
        )
        let fixedSystemFontCount = split.components(separatedBy: ".font(.system(").count - 1
        XCTAssertEqual(
            fixedSystemFontCount,
            2,
            "Only the Settings gear and empty-state illustration should keep fixed system fonts in the browser."
        )
    }

    func testScaledBrowserUsesIntrinsicHeightsAndResponsiveHighZoomFallbacks() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))

        XCTAssertTrue(split.contains(".frame(minHeight: 40)"))
        XCTAssertFalse(split.contains(".frame(height: 40)"))
        XCTAssertTrue(split.contains(".frame(minHeight: 42)"))
        XCTAssertFalse(split.contains(".frame(height: 42)"))
        XCTAssertFalse(split.contains("maxHeight: 32"))
        XCTAssertTrue(split.contains(".frame(minWidth: 35, minHeight: 24)"))
        XCTAssertFalse(split.contains(".frame(width: 35, height: 24)"))
        XCTAssertTrue(split.contains("private var sessionIdentityLine: some View"))
        XCTAssertTrue(split.contains("private var responsiveBrowserFooter: some View"))
        XCTAssertTrue(split.contains("private func permissionHealthActionLabel("))
        XCTAssertFalse(split.contains("Button(actionTitle) {\n                        permissionHealth.performPrimarySetupAction()\n                    }\n                    .controlSize(.small)"))

        let horizontalFallbackCount = split.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1
        XCTAssertGreaterThanOrEqual(
            horizontalFallbackCount,
            3,
            "Rows, footer, and owner actions each need a high-zoom horizontal fallback."
        )
    }

    func testAppearanceKeepsSharedContentSizeCompactInsideDisplayAndPreservesTheLegacyPreferenceKey() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/Core/Settings.swift"))
        let settingsView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/SettingsWindowView.swift"))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let appearanceStart = try XCTUnwrap(settingsView.range(of: "private struct AppearanceSection: View"))
        let appearanceEnd = try XCTUnwrap(settingsView.range(
            of: "private struct PillsSection: View",
            range: appearanceStart.upperBound..<settingsView.endIndex
        ))
        let appearance = String(settingsView[appearanceStart.lowerBound..<appearanceEnd.lowerBound])
        let displayStart = try XCTUnwrap(appearance.range(of: "SettingsSubheading(\"Display\")"))
        let displayGroup = String(appearance[displayStart.lowerBound...])

        XCTAssertTrue(settings.contains("static let chatFontScale = \"chatFontScale\""))
        XCTAssertTrue(settings.contains("static var contentFontScale: Double"))
        XCTAssertTrue(settings.contains("static let contentFontScaleMin: Double = 0.8"))
        XCTAssertTrue(settings.contains("static let contentFontScaleMax: Double = 2.5"))
        XCTAssertTrue(displayGroup.contains("title: \"Content size\""))
        XCTAssertTrue(displayGroup.contains("description: \"Sessions and Chat\""))
        XCTAssertTrue(displayGroup.contains("value: $contentFontScale"))
        XCTAssertFalse(appearance.contains("SettingsSubheading(\"Content font size\""))
        XCTAssertFalse(appearance.contains("SettingsSubheading(\"Chat font size\""))
        XCTAssertFalse(appearance.contains("Button(\"Reset\")"))
        XCTAssertTrue(split.contains("AppSettings.contentFontScale = command.apply("))
    }

    func testViewMenuExposesSharedContentSizeCommands() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let app = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/App/AgentVisorApp.swift"))

        XCTAssertTrue(app.contains("CommandGroup(after: .toolbar)"))
        XCTAssertTrue(app.contains("Button(\"Zoom In\")"))
        XCTAssertTrue(app.contains("Button(\"Zoom Out\")"))
        XCTAssertTrue(app.contains("Button(\"Actual Size\")"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"=\", modifiers: .command)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"-\", modifiers: .command)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"0\", modifiers: .command)"))
        XCTAssertTrue(app.contains("AppSettings.contentFontScale = command.apply("))
        XCTAssertTrue(app.contains("step: AppSettings.contentFontScaleStep"))
        XCTAssertTrue(app.contains("min: AppSettings.contentFontScaleMin"))
        XCTAssertTrue(app.contains("max: AppSettings.contentFontScaleMax"))
    }

    func testSessionsAndTheChatSurfaceUseTheSharedScaleDecoder() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let split = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainSplitView.swift"))
        let windowChat = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/WindowChatView.swift"))

        for source in [split, windowChat] {
            XCTAssertTrue(source.contains("ContentFontScaleCommand.decode("))
            XCTAssertTrue(source.contains("optionHeld:"))
            XCTAssertTrue(source.contains("controlHeld:"))
            XCTAssertTrue(source.contains("AppSettings.contentFontScale"))
        }
    }

    func testHotkeySummonRaisesTheBrowserAboveOtherAppsAsKeyWindow() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let controller = try String(contentsOf: root
            .appendingPathComponent("AgentVisor/UI/Window/MainWindowController.swift"))
        guard let start = controller.range(of: "func show() {")?.lowerBound,
              let end = controller.range(
                of: "func showSessions()",
                range: start..<controller.endIndex
              )?.lowerBound else {
            return XCTFail("Could not isolate MainWindowController.show().")
        }
        let show = String(controller[start..<end])

        guard let activate = show.range(
                of: "NSApp.activate(ignoringOtherApps: true)"
              )?.lowerBound,
              let makeKey = show.range(
                of: "window.makeKeyAndOrderFront(nil)"
              )?.lowerBound,
              let regardless = show.range(
                of: "window.orderFrontRegardless()"
              )?.lowerBound else {
            return XCTFail(
                "show() must activate Agent Visor, promote the window to key, and order it front regardless so a global-hotkey summon rises above other apps on cooperative-activation macOS."
            )
        }
        XCTAssertLessThan(
            activate,
            makeKey,
            "Activate the app before promoting the window to key."
        )
        XCTAssertLessThan(
            makeKey,
            regardless,
            "orderFrontRegardless must run last so the window rises above other apps even when full activation is deferred."
        )
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
