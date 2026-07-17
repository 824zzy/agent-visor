import XCTest
@testable import AgentVisorCore

final class SessionBrowserShortcutEducationPolicyTests: XCTestCase {
    func testControlCommandExplainsNumberedPillsAndMoreSessions() {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(
            for: .controlCommand
        )

        XCTAssertEqual(presentation.title, "Global shortcuts")
        XCTAssertEqual(presentation.hints, [
            SessionBrowserShortcutHint(keys: "⌃⌘1-9", label: "Open numbered pills"),
            SessionBrowserShortcutHint(keys: "⌃⌘0", label: "More Sessions"),
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
            "Global session shortcuts are off · Configure in Settings"
        )
    }
}
