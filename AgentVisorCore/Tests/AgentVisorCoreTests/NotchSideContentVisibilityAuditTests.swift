import XCTest

final class NotchSideContentVisibilityAuditTests: XCTestCase {
    func testPillVisibilityUsesHybridSurfacePolicy() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("PillSurfacePolicy.select"),
            "Pill visibility should flow through the Core hybrid surface policy."
        )
        XCTAssertTrue(
            source.contains("isTitleless: isTitleless(session)"),
            "Pill visibility should still exclude titleless rows before active/recent shortcut selection."
        )
        XCTAssertFalse(
            source.contains("isObservedActiveOnlyIdle"),
            "Pill visibility should not branch on observed/source-specific idle state."
        )
        XCTAssertFalse(
            source.contains("isIdle: session.phase == .idle"),
            "Idle sessions are no longer categorically hidden; the hybrid policy may admit them as recent shortcuts."
        )
    }

    func testPillBarUsesHybridSurfacePolicyInsteadOfProjectRoundRobin() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("PillSurfacePolicy.select"),
            "Menu-bar pill selection should use the hybrid active-plus-recent-shortcut surface policy."
        )
        XCTAssertFalse(
            source.contains("ProjectAwarePillOrder.orderedIds"),
            "Pill ordering should not round-robin by project; state priority and recency should decide order."
        )
    }

    func testRecentShortcutPillsAreStyledDistinctly() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("let role: PillSurfaceRole"),
            "Visible pills should carry their active/recent role through to rendering."
        )
        XCTAssertTrue(
            source.contains("role == .recentShortcut"),
            "Recent shortcut pills should use a dimmer style than active status pills."
        )
    }

    func testAllMenuBarPillsShareTwentyFourPointHeight() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(source.contains("enum MenuBarPillMetrics"))
        XCTAssertTrue(source.contains("static let height: CGFloat = 24"))
        XCTAssertEqual(
            source.components(separatedBy: "height: MenuBarPillMetrics.height").count - 1,
            3,
            "Session, overflow, and usage pills should share the same fixed height."
        )
    }

    func testMenuBarPillTypographyAndPaddingUseSharedMetrics() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(source.contains("static let sessionFontSize: CGFloat = 11"))
        XCTAssertTrue(source.contains("static let usageFontSize: CGFloat = 10.5"))
        XCTAssertTrue(source.contains("static let horizontalPadding: CGFloat = 7"))
        XCTAssertTrue(source.contains("static let statusDotDiameter: CGFloat = 6"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "MenuBarPillMetrics.sessionFontSize").count - 1,
            3,
            "Session rendering, overflow rendering, and width measurement must share the font size."
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "MenuBarPillMetrics.horizontalPadding").count - 1,
            3,
            "Session rendering and width estimates must use the same metric."
        )
        XCTAssertTrue(source.contains("width: PillBarCoordinator.overflowPillWidth(count: count)"))
        XCTAssertTrue(source.contains("MenuBarPillMetrics.usageFontSize"))
    }

    func testPillOverflowCountsAllNonVisibleWorkspaceSessions() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("hiddenVisibleCount"),
            "The +N overflow pill should count every workspace session not rendered as a pill."
        )
        XCTAssertTrue(
            source.contains("result.hiddenIds.compactMap"),
            "Overflow count and rows should come from the exact active-plus-recent IDs omitted by the packer."
        )
    }

    func testOverflowPopoverUsesOnlySessionsOmittedByTheRenderedPillPack() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sideContentSource = try String(contentsOf: notchSideContentURL(from: testFile))
        let notchViewSource = try String(contentsOf: notchViewURL(from: testFile))

        XCTAssertTrue(
            sideContentSource.contains("let overflowSessions: [SessionState]"),
            "The pack result should carry the exact sessions represented by +N."
        )
        XCTAssertTrue(
            sideContentSource.contains("result.hiddenIds.compactMap"),
            "Overflow sessions should come from the packer's hidden IDs, preserving priority order."
        )
        XCTAssertTrue(
            notchViewSource.contains("from: pack.overflowSessions"),
            "The +N popover snapshot should be built from hidden sessions only."
        )
        XCTAssertFalse(
            notchViewSource.contains("snapshot: navigatorSnapshot"),
            "The +N popover must not receive the full workspace snapshot and duplicate visible pills."
        )
    }

    func testOverflowPopoverFreezesOverflowAndSearchCatalogWhileOpen() throws {
        let source = try String(contentsOf: notchViewURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("@State private var frozenOverflowSnapshot: SidebarSessionListSnapshot?"),
            "The open popover should own a stable snapshot instead of following background re-packs."
        )
        XCTAssertTrue(
            source.contains("var overflowSnapshot: SidebarSessionListSnapshot?"),
            "The rendered pill snapshot should retain the exact overflow rows represented by +N."
        )
        XCTAssertTrue(
            source.contains("frozenOverflowSnapshot = pillSnapshotStore.overflowSnapshot"),
            "Opening +N should freeze the same overflow snapshot used by the rendered layout."
        )
        XCTAssertTrue(
            source.contains("snapshot: frozenOverflowSnapshot ?? liveOverflowSnapshot"),
            "While open, the popover should prefer its frozen snapshot over live background updates."
        )
        XCTAssertTrue(
            source.contains("@State private var frozenNavigatorSnapshot: SidebarSessionListSnapshot?"),
            "All-session search should use a stable catalog captured with the overflow rows."
        )
        XCTAssertTrue(
            source.contains("frozenNavigatorSnapshot = pillSnapshotStore.navigatorSnapshot"),
            "Opening +N should freeze the complete recent catalog used by search."
        )
        XCTAssertTrue(
            source.contains("allSessionsSnapshot: frozenNavigatorSnapshot ?? navigatorSnapshot"),
            "Search should use the frozen recent catalog while the popover is open."
        )
    }

    func testOverflowPopoverSupportsInlineSearchWithoutBecomingTheFullBrowser() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sideContentSource = try String(contentsOf: notchSideContentURL(from: testFile))
        let notchViewSource = try String(contentsOf: notchViewURL(from: testFile))

        XCTAssertTrue(sideContentSource.contains("let totalSessionCount: Int"))
        XCTAssertTrue(sideContentSource.contains("let allSessionsSnapshot: SidebarSessionListSnapshot"))
        XCTAssertTrue(sideContentSource.contains("SessionNavigatorSummaryPolicy.overflowTitle"))
        XCTAssertTrue(
            sideContentSource.contains("SessionNavigatorSummaryPolicy.searchPlaceholder(")
                && sideContentSource.contains("totalSessionCount: totalSessionCount")
        )
        XCTAssertTrue(
            sideContentSource.contains("SessionNavigatorSearchPolicy.select(")
        )
        XCTAssertTrue(
            sideContentSource.contains("SessionNavigatorSummaryPolicy.openBrowserLabel")
        )
        XCTAssertTrue(
            notchViewSource.contains("totalSessionCount: navigatorSnapshot.flatRows.count"),
            "Search should advertise the complete recent catalog count, not the hidden-row count."
        )
    }

    func testSessionNavigatorPopoverShowsStatusFreshnessText() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("statusFreshnessText"),
            "Navigator rows should expose the status freshness/inference gap instead of only showing an age chip."
        )
        XCTAssertTrue(
            source.contains("phaseObservedAt"),
            "Freshness text should use the latest observed status time, not only phaseChangedAt."
        )
        XCTAssertTrue(
            source.contains("synced"),
            "Fresh status labels should include synced timing when the phase was observed recently."
        )
    }

    func testNavigationRecencyIsRecordedFromPillsAndNavigator() throws {
        let source = try String(contentsOf: notchViewURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionNavigationRecencyStore.shared.record"),
            "Pill clicks and navigator selections should record navigation recency so idle sessions can become recent shortcuts."
        )
        XCTAssertTrue(
            source.contains("recordNavigationRecency"),
            "Navigation recency recording should be centralized at the click/navigation dispatch layer."
        )
    }

    func testNavigationRecencyImmediatelyInvalidatesPillLayout() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sideContentSource = try String(contentsOf: notchSideContentURL(from: testFile))
        let notchViewSource = try String(contentsOf: notchViewURL(from: testFile))

        XCTAssertTrue(
            sideContentSource.contains("final class SessionNavigationRecencyStore: ObservableObject"),
            "Navigation recency must publish changes instead of waiting for an unrelated session update."
        )
        XCTAssertTrue(
            sideContentSource.contains("@Published private(set) var revision"),
            "The recency store should expose a lightweight layout invalidation signal."
        )
        XCTAssertTrue(
            notchViewSource.contains("@ObservedObject private var navigationRecencyStore"),
            "The menu-bar surface must observe navigation recency changes."
        )
        XCTAssertTrue(
            notchViewSource.contains("navigationRecencyStore.revision"),
            "Pill layout should establish an explicit dependency on the recency revision."
        )
    }

    func testWindowSidebarVisibilityKeepsIdleSessionsNavigable() throws {
        let source = try String(contentsOf: mainWindowViewModelURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SidebarSessionVisibilityPolicy.shouldHideInWindow"),
            "Window sidebar visibility should go through the shared policy."
        )
        XCTAssertFalse(
            source.contains("isIdle:"),
            "Window sidebar should not hide idle sessions; the main window is the recent workspace."
        )
    }

    func testSessionsNavigatorUsesWindowVisibilityNotPillVisibility() throws {
        let source = try String(contentsOf: mainWindowViewModelURL(from: URL(fileURLWithPath: #filePath)))
        guard let start = source.range(of: "enum SidebarSessionListBuilder")?.lowerBound else {
            return XCTFail("Could not locate SidebarSessionListBuilder implementation.")
        }
        let builder = String(source[start...])
        XCTAssertTrue(
            builder.contains("SidebarSessionVisibilityPolicy.shouldHideInWindow"),
            "Sessions navigator should share the main-window recent workspace visibility policy."
        )
        XCTAssertFalse(
            builder.contains("shouldHideInPills"),
            "Sessions navigator must not use pill visibility, because observed idle sessions remain navigable."
        )
    }

    func testDedicatedSessionsNavigatorButtonIsRemovedFromMenuBar() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(contentsOf: notchViewURL(from: testFile))
        let sideContent = try String(contentsOf: notchSideContentURL(from: testFile))
        let coreSources = repoRootURL(from: testFile)
            .appendingPathComponent("AgentVisorCore/Sources/AgentVisorCore")
        XCTAssertFalse(
            source.contains("SessionNavigatorButtonLayout.layout"),
            "NotchView should not reserve width for a dedicated Sessions N button."
        )
        XCTAssertFalse(
            source.contains("SessionNavigatorButtonMetrics.label"),
            "The menu bar should no longer render a dedicated Sessions N label."
        )
        XCTAssertFalse(
            source.contains("sessionNavigatorButton(label:"),
            "The menu-bar Sessions control should be the +N overflow pill, not a separate button."
        )
        XCTAssertFalse(sideContent.contains("struct SessionNavigatorButton:"))
        XCTAssertFalse(sideContent.contains("enum SessionNavigatorButtonMetrics"))
        XCTAssertFalse(source.contains("sessionNavigatorSentinel"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: coreSources.appendingPathComponent("SessionNavigatorButtonLayout.swift").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: coreSources.appendingPathComponent("SessionNavigatorButtonLabelPolicy.swift").path
            )
        )
    }

    func testPillPackingUsesNavigatorWorkspaceListWithoutDedicatedReservation() throws {
        let source = try String(contentsOf: notchViewURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("let navigatorPillSessions = navigatorSnapshot.flatRows.compactMap"),
            "The pill strip should pack the same recent workspace list as the navigator."
        )
        XCTAssertTrue(
            source.contains("leftMax: leftSafeWidth"),
            "Pill packing should use the full left menu-bar budget without reserving Sessions N width."
        )
        XCTAssertTrue(
            source.contains("rightMax: rightSafeWidth"),
            "Pill packing should use the full right menu-bar budget without reserving Sessions N width."
        )
    }

    func testSessionsNavigatorPopoverRendersStateSummaryHeader() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionNavigatorSummaryPolicy.headerText"),
            "The Sessions popover header should explain the current workspace state counts."
        )
        XCTAssertTrue(
            source.contains("navigatorSummary"),
            "The popover should derive one summary from the visible navigator snapshot."
        )
    }

    func testSessionsNavigatorPopoverUsesWideScreenSafeWidthPolicy() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionNavigatorPopoverLayoutPolicy.width"),
            "The Sessions popover should use a wider screen-safe width policy instead of a cramped fixed width."
        )
        XCTAssertFalse(
            source.contains(".frame(width: 360)"),
            "The Sessions popover should not keep the old cramped 360px width."
        )
    }

    func testSessionsNavigatorRowPrioritizesTitleBeforeMetadataChips() throws {
        let source = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private var titleLine"),
            "The navigator row should keep the title on a dedicated first line."
        )
        XCTAssertTrue(
            source.contains("private var metadataLine"),
            "The navigator row should move source/project chips to a secondary metadata line."
        )
    }

    func testOverflowPillUsesPillSnapshotCoordinates() throws {
        let source = try String(contentsOf: notchViewURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertFalse(
            source.contains("SessionNavigatorButtonHitTargetBuilder.target"),
            "The removed Sessions button should not have a separate hit target."
        )
        XCTAssertFalse(
            source.contains("sessionNavigatorHitTarget"),
            "Navigator opening should be driven by the +N overflow pill's normal pill snapshot hit testing."
        )
        XCTAssertFalse(
            source.contains("sessionNavigatorFrame.contains(mousePos)"),
            "SwiftUI .global frames do not belong in the click resolver; they can miss menu-bar clicks."
        )
    }

    func testOverflowPillTogglesSessionsPopover() throws {
        let notchViewSource = try String(contentsOf: notchViewURL(from: URL(fileURLWithPath: #filePath)))
        let sideContentSource = try String(contentsOf: notchSideContentURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            notchViewSource.contains("GlobalSessionShortcutPolicy.overflowAction(")
                && notchViewSource.contains("isPresented: showSessionNavigatorPopover"),
            "Clicking +N again while the popover is opening/open should dismiss it."
        )
        XCTAssertTrue(
            notchViewSource.contains("showSessionNavigatorPopover = willShowNavigatorPopover"),
            "+N clicks should assign the toggled state instead of forcing the popover open."
        )
        XCTAssertTrue(
            sideContentSource.contains("OverflowPopoverConfiguration"),
            "The +N overflow pill should own the Sessions popover anchor."
        )
        XCTAssertTrue(
            sideContentSource.contains(".popover(isPresented: overflowPopover.isPresented"),
            "The popover should be attached to the rendered +N pill."
        )
    }

    private func notchSideContentURL(from testFile: URL) -> URL {
        let repoRoot = repoRootURL(from: testFile)
        return repoRoot
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("NotchSideContent.swift")
    }

    private func mainWindowViewModelURL(from testFile: URL) -> URL {
        let repoRoot = repoRootURL(from: testFile)
        return repoRoot
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainWindowViewModel.swift")
    }

    private func notchViewURL(from testFile: URL) -> URL {
        let repoRoot = repoRootURL(from: testFile)
        return repoRoot
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("NotchView.swift")
    }

    private func repoRootURL(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
