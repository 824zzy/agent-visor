import XCTest
@testable import AgentVisorCore

final class NativeMenuHotkeyStateTests: XCTestCase {
    func testFiresOnlyAfterAConfiguredCleanDoubleTap() {
        var state = NativeMenuHotkeyState()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(state.modifierFlagsChanged(.shift, at: start))
        XCTAssertFalse(state.modifierFlagsChanged([], at: start.addingTimeInterval(0.04)))
        XCTAssertFalse(state.modifierFlagsChanged(.shift, at: start.addingTimeInterval(0.12)))
        XCTAssertTrue(state.modifierFlagsChanged([], at: start.addingTimeInterval(0.16)))

        state.configure(trigger: .off, customCombo: nil)
        XCTAssertFalse(state.modifierFlagsChanged(.shift, at: start.addingTimeInterval(1)))
        XCTAssertFalse(state.modifierFlagsChanged([], at: start.addingTimeInterval(1.04)))
    }

    func testFiresTheConfiguredCustomChord() {
        var state = NativeMenuHotkeyState()
        state.configure(
            trigger: .custom,
            customCombo: KeyCombo(keyCode: 38, modifiers: .command)
        )

        XCTAssertFalse(state.keyDown(keyCode: 38, modifiers: [], at: Date()))
        XCTAssertTrue(state.keyDown(keyCode: 38, modifiers: .command, at: Date()))
    }
}
