import XCTest
@testable import AgentVisorCore

/// Custom hotkey combo (one keycode + modifier mask) chosen by the
/// user in Preferences. Used by the host app's HotkeyManager when the
/// trigger mode is `.custom` — replaces the double-tap-modifier path
/// with a single-press chord. Pure-logic surface tested here:
/// serialization for UserDefaults, validation (reject combos that would
/// fire from normal typing), and display-formatting for the picker UI.
final class KeyComboTests: XCTestCase {

    // MARK: - Serialization

    func test_givenKeyCombo_whenSerializedAndDeserialized_thenRoundTripsExactly() {
        // Given a Cmd+Shift+Space combo (keyCode 49)
        let original = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        // When serialized and parsed back
        let restored = KeyCombo.fromSerialized(original.serialized())
        // Then equal to original
        XCTAssertEqual(restored, original)
    }

    func test_givenMalformedSerializedString_whenParsed_thenReturnsNil() {
        // Given garbage strings
        XCTAssertNil(KeyCombo.fromSerialized(""))
        XCTAssertNil(KeyCombo.fromSerialized("notacombo"))
        XCTAssertNil(KeyCombo.fromSerialized("49"))
        XCTAssertNil(KeyCombo.fromSerialized(":1"))
        XCTAssertNil(KeyCombo.fromSerialized("abc:def"))
    }

    func test_givenEqualCombos_thenEqualityHolds() {
        // Given two combos with identical fields
        let a = KeyCombo(keyCode: 8, modifiers: [.command, .control])
        let b = KeyCombo(keyCode: 8, modifiers: [.control, .command])
        // Then equal (OptionSet ordering doesn't matter)
        XCTAssertEqual(a, b)
    }

    // MARK: - Validation

    func test_givenLetterKeyWithModifier_thenValid() {
        // Given Cmd+C (keyCode 8 = C)
        let combo = KeyCombo(keyCode: 8, modifiers: [.command])
        // Then accepted — modifier-plus-letter is a normal hotkey shape
        XCTAssertTrue(KeyComboValidator.isValid(combo))
    }

    func test_givenLetterKeyWithoutModifier_thenInvalid() {
        // Given just `a` with no modifier
        let combo = KeyCombo(keyCode: 0, modifiers: [])
        // Then rejected — would fire from normal typing
        XCTAssertFalse(KeyComboValidator.isValid(combo))
    }

    func test_givenFunctionKeyAlone_thenValid() {
        // Given F13 (keyCode 105) with no modifier
        let combo = KeyCombo(keyCode: 105, modifiers: [])
        // Then accepted — F-keys aren't part of typing
        XCTAssertTrue(KeyComboValidator.isValid(combo))
    }

    func test_givenF1Alone_thenValid() {
        // Given F1 (keyCode 122) with no modifier
        let combo = KeyCombo(keyCode: 122, modifiers: [])
        // Then accepted
        XCTAssertTrue(KeyComboValidator.isValid(combo))
    }

    func test_givenSpaceAlone_thenInvalid() {
        // Given Space (keyCode 49) with no modifier
        let combo = KeyCombo(keyCode: 49, modifiers: [])
        // Then rejected — space is the most-pressed key in typing
        XCTAssertFalse(KeyComboValidator.isValid(combo))
    }

    func test_givenEscapeAlone_thenInvalid() {
        // Given Esc (keyCode 53) with no modifier
        let combo = KeyCombo(keyCode: 53, modifiers: [])
        // Then rejected — agent-visor uses Esc to close the chat
        XCTAssertFalse(KeyComboValidator.isValid(combo))
    }

    // MARK: - Display formatting

    func test_givenCmdC_whenFormatted_thenShowsApplePatternGlyphs() {
        // Given Cmd+C
        let combo = KeyCombo(keyCode: 8, modifiers: [.command])
        // When formatted
        let display = KeyComboFormatter.display(combo)
        // Then "⌘C" — Apple's standard order is ⌃⌥⇧⌘ then key
        XCTAssertEqual(display, "⌘C")
    }

    func test_givenCtrlOptShiftCmdC_whenFormatted_thenShowsAllModifiersInOrder() {
        // Given all four modifiers plus C
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift, .command])
        // When formatted
        let display = KeyComboFormatter.display(combo)
        // Then glyphs in Apple's canonical order
        XCTAssertEqual(display, "⌃⌥⇧⌘C")
    }

    func test_givenF13Alone_whenFormatted_thenShowsFnKeyName() {
        // Given F13 with no modifier
        let combo = KeyCombo(keyCode: 105, modifiers: [])
        // When formatted
        let display = KeyComboFormatter.display(combo)
        // Then "F13"
        XCTAssertEqual(display, "F13")
    }

    func test_givenSpaceWithModifier_whenFormatted_thenShowsSpaceLiteral() {
        // Given Cmd+Shift+Space
        let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        // When formatted
        let display = KeyComboFormatter.display(combo)
        // Then space is spelled out (the glyph " " would be invisible in the UI)
        XCTAssertEqual(display, "⇧⌘Space")
    }

    func test_givenUnknownKeyCode_whenFormatted_thenFallsBackToCode() {
        // Given a keycode the table doesn't recognize
        let combo = KeyCombo(keyCode: 999, modifiers: [.command])
        // When formatted
        let display = KeyComboFormatter.display(combo)
        // Then a printable fallback so the UI never crashes
        XCTAssertEqual(display, "⌘Key999")
    }
}
