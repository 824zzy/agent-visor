//
//  SessionHotkeyMatcher.swift
//  AgentVisorCore
//
//  Maps a digit keystroke (from `NSEvent.charactersIgnoringModifiers`)
//  to a 0-based sidebar position for the Cmd+1..Cmd+9 session-switch
//  hotkey. Pure-string predicate so the matcher is unit-testable
//  without dragging AppKit into the test bundle.
//
//  Cmd+0 is deliberately UNMAPPED — that combo resets the chat font
//  scale, which is muscle-memory load-bearing for users who zoom
//  with Cmd+= / Cmd+- while reading. Sessions 10+ have no hotkey,
//  matching Slack's well-known Cmd+1..9 idiom.
//

import Foundation

public enum SessionHotkeyMatcher {
    /// Returns a 0-based sidebar position if the keystroke is a
    /// single ASCII digit 1–9, else nil.
    ///
    /// Mapping:
    ///   "1" → 0 (first session in the flat sidebar order)
    ///   "9" → 8 (ninth)
    ///   "0", letters, multi-char strings, unicode digits → nil
    ///
    /// Caller is responsible for confirming the modifier mask is
    /// exactly `.command` (no shift/option/control) before calling
    /// this; the matcher only inspects the character.
    public static func position(forKeyCharacter char: String) -> Int? {
        // Reject empty, multi-char (e.g. composed sequences), and
        // anything outside ASCII digits. `Int(char)` would happily
        // parse a unicode "²" as 2, which we don't want.
        guard char.count == 1,
              let scalar = char.unicodeScalars.first,
              (UnicodeScalar("1").value...UnicodeScalar("9").value).contains(scalar.value)
        else {
            return nil
        }
        return Int(scalar.value - UnicodeScalar("1").value)
    }
}
