import XCTest

final class SessionNavigationAccessibilityAuditTests: XCTestCase {
    func testSessionRowsExposeKeyboardAndAccessibilityActions() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sidebar = try source(root, "AgentVisor/UI/Window/WindowSidebarRow.swift")
        let popover = try source(root, "AgentVisor/UI/Components/NotchSideContent.swift")
        let logo = try source(root, "AgentVisor/UI/Components/AgentBrandLogo.swift")

        XCTAssertTrue(sidebar.contains(".accessibilityAction { onChat() }"))
        XCTAssertTrue(sidebar.contains(".focusable()"))
        XCTAssertTrue(sidebar.contains(".onKeyPress(.return)"))
        XCTAssertTrue(sidebar.contains(".accessibilityAction(named: removalActionLabel)"))
        XCTAssertTrue(popover.contains("Button(action: selectSessionFromSwiftUI)"))
        XCTAssertTrue(popover.contains("button.setAccessibilityElement(false)"))
        XCTAssertTrue(logo.contains(".accessibilityHidden(true)"))
    }

    func testSessionPopoverFreshnessUsesPeriodicClock() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let popover = try source(root, "AgentVisor/UI/Components/NotchSideContent.swift")

        XCTAssertTrue(popover.contains("TimelineView(.periodic"))
        XCTAssertTrue(popover.contains("now: context.date"))
        XCTAssertFalse(popover.contains("Date().timeIntervalSince(observedAt)"))
    }

    func testMenuBarEntryPointIsAlwaysAvailableForKeyboardAndVoiceOverUsers() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let controller = try source(
            root,
            "AgentVisor/UI/Window/PillAccessibilityStatusItemController.swift"
        )
        let appDelegate = try source(root, "AgentVisor/App/AppDelegate.swift")

        XCTAssertTrue(controller.contains("NSStatusBar.system.statusItem"))
        XCTAssertTrue(controller.contains("setAccessibilityLabel"))
        XCTAssertTrue(controller.contains("NotchPanelRedirect.openMainWindow?()"))
        XCTAssertTrue(appDelegate.contains("PillAccessibilityStatusItemController.shared.start()"))
        XCTAssertFalse(
            controller.contains("isVoiceOverEnabled"),
            "The menu-bar entry point must not depend on VoiceOver being on."
        )
        XCTAssertFalse(
            controller.contains("hasPhysicalNotch"),
            "The menu-bar entry point must not depend on notch hardware; it is the only menu-bar path to the session browser on every display."
        )
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
