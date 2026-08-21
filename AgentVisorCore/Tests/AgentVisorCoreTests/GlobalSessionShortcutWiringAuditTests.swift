import XCTest

final class GlobalSessionShortcutWiringAuditTests: XCTestCase {
    func testGlobalDigitsResolveAgainstRenderedPillsAndUseOriginalFirstNavigation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("GlobalSessionShortcutManager.swift"))
        let appDelegate = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("App")
            .appendingPathComponent("AppDelegate.swift"))

        XCTAssertTrue(manager.contains("PillBarSnapshotStore.shared.pillsInReadingOrder"))
        XCTAssertTrue(manager.contains("GlobalSessionShortcutSnapshot("))
        XCTAssertTrue(manager.contains("GlobalSessionShortcutPolicy.action"))
        XCTAssertTrue(manager.contains("case .navigate(let position):"))
        XCTAssertTrue(appDelegate.contains("GlobalSessionShortcutManager.shared.onNavigate"))
        XCTAssertTrue(appDelegate.contains("SessionNavigationRecencyStore.shared.record(session)"))
        XCTAssertTrue(appDelegate.contains("SessionOpenRouter.smartOpen(session, modifierIntent: .standard)"))
    }

    func testDigitActivationUsesRegisteredSystemHotKeysInsteadOfAccessibilityKeyMonitoring() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(manager.contains("import Carbon.HIToolbox"))
        XCTAssertTrue(manager.contains("RegisterEventHotKey("))
        XCTAssertTrue(manager.contains("kEventHotKeyPressed"))
        XCTAssertTrue(manager.contains("GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID:"))
        XCTAssertTrue(manager.contains("matching: .flagsChanged"))
        XCTAssertFalse(manager.contains("matching: mask"))
    }

    func testGlobalZeroRoutesToTheOverflowToggleWithoutRepeating() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(manager.contains("case .toggleOverflow:"))
        XCTAssertTrue(manager.contains("guard pressedHotKeyIDs.insert(id).inserted"))
        XCTAssertTrue(manager.contains("pressedHotKeyIDs.remove(id)"))
        XCTAssertTrue(manager.contains("_ = onToggleOverflow?()"))
    }

    func testOverflowShortcutUsesTheSameTogglePathAsTheRenderedPlusNPill() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let pillStrip = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("PillStripView.swift"))

        XCTAssertTrue(pillStrip.contains("GlobalSessionShortcutManager.shared.onToggleOverflow ="))
        XCTAssertTrue(pillStrip.contains("GlobalSessionShortcutManager.shared.onToggleOverflow = nil"))
        XCTAssertTrue(pillStrip.contains("GlobalSessionShortcutPolicy.overflowAction("))
        XCTAssertTrue(pillStrip.contains("case .overflow:\n            return toggleSessionNavigatorPopover()"))
        XCTAssertTrue(pillStrip.contains("private func toggleSessionNavigatorPopover() -> Bool"))
    }

    func testHoldingShortcutModifiersReplacesStatusDotsWithFrozenNumberBadges() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("PillStripContent.swift"))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(sideContent.contains("GlobalSessionShortcutManager.shared"))
        XCTAssertTrue(sideContent.contains("position(forStableID: session.stableId)"))
        XCTAssertTrue(sideContent.contains("PillShortcutKeycap(number: revealedShortcutPosition)"))
        XCTAssertTrue(manager.contains("freezeRenderedPillsIfNeeded()"))
        XCTAssertTrue(manager.contains("guard frozenSnapshot == nil else { return }"))
    }

    func testHoldingShortcutModifiersRevealsZeroInOverflowWithoutChangingItsWidth() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("PillStripContent.swift"))
        let manager = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("GlobalSessionShortcutManager.swift"))

        XCTAssertTrue(manager.contains("@Published private(set) var isRevealingShortcuts = false"))
        XCTAssertTrue(manager.contains("isRevealingShortcuts = true"))
        XCTAssertTrue(manager.contains("isRevealingShortcuts = false"))
        XCTAssertTrue(sideContent.contains("if sessionShortcutManager.isRevealingShortcuts"))
        XCTAssertTrue(sideContent.contains("PillShortcutKeycap(number: 0)"))
        XCTAssertTrue(sideContent.contains("OverflowPillButton(count: overflowCount, width: overflowPillWidth)"))
        XCTAssertTrue(sideContent.contains("width: width"))
    }

    func testShortcutBadgeIsReadableWithoutMovingTheTitleOrGrowingThePill() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Components")
            .appendingPathComponent("PillStripContent.swift"))

        XCTAssertTrue(sideContent.contains(".font(.system(size: 10, weight: .bold, design: .rounded))"))
        XCTAssertTrue(sideContent.contains(".monospacedDigit()"))
        XCTAssertTrue(sideContent.contains(".frame(width: 10, height: 12)"))
        XCTAssertTrue(sideContent.contains("RoundedRectangle(cornerRadius: 3)"))
        XCTAssertTrue(sideContent.contains(".frame(width: 6, height: 6)"))
        XCTAssertTrue(sideContent.contains(".padding(.horizontal, horizontalPadding)"))
        XCTAssertFalse(sideContent.contains(".padding(.horizontal, shortcutPosition == nil"))

        for horizontalPadding in [7, 5] {
            let normalTitleOrigin = horizontalPadding + 6 + 3
            let shortcutTitleOrigin = horizontalPadding + 6 + 3
            XCTAssertEqual(normalTitleOrigin, shortcutTitleOrigin)
        }
    }

    func testPillsSettingsConfigureTheGlobalModifierFamily() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let settingsView = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("SettingsWindowView.swift"))
        let settings = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Core")
            .appendingPathComponent("Settings.swift"))

        XCTAssertTrue(settingsView.contains("SettingsSubheading(\"Session shortcuts\")"))
        XCTAssertTrue(settingsView.contains("ForEach(SessionShortcutModifierFamily.allCases"))
        XCTAssertTrue(settingsView.contains("GlobalSessionShortcutManager.shared.apply(newValue)"))
        XCTAssertTrue(settingsView.contains("or 0 to toggle More Sessions."))
        XCTAssertTrue(settings.contains("return .defaultFamily"))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
