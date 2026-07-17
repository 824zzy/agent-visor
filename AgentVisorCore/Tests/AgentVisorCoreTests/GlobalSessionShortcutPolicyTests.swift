import XCTest
@testable import AgentVisorCore

final class GlobalSessionShortcutPolicyTests: XCTestCase {
    func testRenderedPillsMapToShortcutPositionsInReadingOrder() {
        let snapshot = GlobalSessionShortcutSnapshot(
            leftVisibleSessionIDs: ["left-far", "left-near"],
            rightVisibleSessionIDs: ["right-near", "right-far"]
        )

        XCTAssertEqual(snapshot.targetSessionID(forPosition: 0), "left-far")
        XCTAssertEqual(snapshot.targetSessionID(forPosition: 1), "left-near")
        XCTAssertEqual(snapshot.targetSessionID(forPosition: 2), "right-near")
        XCTAssertEqual(snapshot.targetSessionID(forPosition: 3), "right-far")
    }

    func testOnlyFirstNineRenderedPillsReceiveDirectShortcuts() {
        let snapshot = GlobalSessionShortcutSnapshot(
            leftVisibleSessionIDs: (1...5).map { "left-\($0)" },
            rightVisibleSessionIDs: (1...7).map { "right-\($0)" }
        )

        XCTAssertEqual(snapshot.targetSessionID(forPosition: 8), "right-4")
        XCTAssertNil(snapshot.targetSessionID(forPosition: 9))
    }

    func testSnapshotExposesOneBasedPositionsForPillBadges() {
        let snapshot = GlobalSessionShortcutSnapshot(
            leftVisibleSessionIDs: ["first", "second"],
            rightVisibleSessionIDs: ["third"]
        )

        XCTAssertEqual(snapshot.displayPosition(forSessionID: "first"), 1)
        XCTAssertEqual(snapshot.displayPosition(forSessionID: "third"), 3)
        XCTAssertNil(snapshot.displayPosition(forSessionID: "missing"))
    }

    func testControlCommandFamilyArmsOnlyForExactModifiers() {
        XCTAssertTrue(GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: [.control, .command],
            family: .controlCommand
        ))
        XCTAssertFalse(GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: [.command],
            family: .controlCommand
        ))
        XCTAssertFalse(GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: [.control, .shift, .command],
            family: .controlCommand
        ))
        XCTAssertFalse(GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: [],
            family: .off
        ))
    }

    func testConfigurableFamiliesExposeSafeModifierSets() {
        XCTAssertEqual(SessionShortcutModifierFamily.controlCommand.modifiers, [.control, .command])
        XCTAssertEqual(SessionShortcutModifierFamily.optionCommand.modifiers, [.option, .command])
        XCTAssertEqual(
            SessionShortcutModifierFamily.controlOptionCommand.modifiers,
            [.control, .option, .command]
        )
        XCTAssertEqual(SessionShortcutModifierFamily.off.modifiers, [])
    }

    func testModifierFamiliesHaveUserFacingShortcutLabels() {
        XCTAssertEqual(SessionShortcutModifierFamily.controlCommand.displayLabel, "⌃⌘1-9")
        XCTAssertEqual(SessionShortcutModifierFamily.optionCommand.displayLabel, "⌥⌘1-9")
        XCTAssertEqual(SessionShortcutModifierFamily.controlOptionCommand.displayLabel, "⌃⌥⌘1-9")
        XCTAssertEqual(SessionShortcutModifierFamily.off.displayLabel, "Off")
    }

    func testEnabledFamilyFormatsTheExactPillShortcutForHoverGuidance() {
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.displayLabel(
                forPosition: 3,
                family: .optionCommand
            ),
            "⌥⌘3"
        )
        XCTAssertNil(GlobalSessionShortcutPolicy.displayLabel(forPosition: 3, family: .off))
        XCTAssertNil(GlobalSessionShortcutPolicy.displayLabel(forPosition: 10, family: .optionCommand))
    }

    func testDigitZeroTogglesOverflowWhileOneThroughNineNavigatePills() {
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.action(forKeyCharacter: "0"),
            .toggleOverflow
        )
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.action(forKeyCharacter: "1"),
            .navigate(position: 0)
        )
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.action(forKeyCharacter: "9"),
            .navigate(position: 8)
        )
        XCTAssertNil(GlobalSessionShortcutPolicy.action(forKeyCharacter: "+"))
        XCTAssertNil(GlobalSessionShortcutPolicy.action(forKeyCharacter: "a"))
    }

    func testRegisteredHotKeysCoverZeroThroughNine() {
        let shortcuts = GlobalSessionShortcutPolicy.registeredHotKeys

        XCTAssertEqual(shortcuts.map(\.digit), Array(0...9))
        XCTAssertEqual(shortcuts.map(\.keyCode), [29, 18, 19, 20, 21, 23, 22, 26, 28, 25])
        XCTAssertEqual(
            shortcuts.map { GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID: $0.id) },
            [.toggleOverflow] + (0..<9).map { .navigate(position: $0) }
        )
    }

    func testOverflowShortcutOpensOnlyWhenOverflowExistsAndAlwaysCloses() {
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.overflowAction(isPresented: false, hasOverflow: true),
            .open
        )
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.overflowAction(isPresented: true, hasOverflow: false),
            .close
        )
        XCTAssertEqual(
            GlobalSessionShortcutPolicy.overflowAction(isPresented: false, hasOverflow: false),
            .ignore
        )
    }
}
