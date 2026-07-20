import XCTest
@testable import AgentVisorCore

final class SessionBrowserShortcutEducationPolicyTests: XCTestCase {
    func testControlCommandExplainsNumberedPillsAndMoreSessions() {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(
            for: .controlCommand
        )

        XCTAssertEqual(presentation.hints, [
            SessionBrowserShortcutHint(keys: "⌃⌘1-9", label: "Open pills"),
            SessionBrowserShortcutHint(keys: "⌃⌘0", label: "More sessions"),
        ])
        XCTAssertNil(presentation.disabledMessage)
    }

    func testGuidanceUsesTheConfiguredModifierFamily() {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(
            for: .optionCommand
        )

        XCTAssertEqual(presentation.hints.map(\.keys), ["⌥⌘1-9", "⌥⌘0"])
    }

    func testDisabledShortcutsDirectUsersToSettingsWithoutFakeKeys() {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(for: .off)

        XCTAssertTrue(presentation.hints.isEmpty)
        XCTAssertEqual(
            presentation.disabledMessage,
            "Global shortcuts off · Configure in Settings"
        )
    }
}
