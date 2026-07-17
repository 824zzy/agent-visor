import Foundation

/// AppKit-free mirror of `NSEvent.ModifierFlags`. The host app converts
/// to/from `NSEvent.ModifierFlags` at the boundary so Core stays
/// pure-Foundation.
public struct ModifierMask: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift   = ModifierMask(rawValue: 1 << 0)
    public static let control = ModifierMask(rawValue: 1 << 1)
    public static let option  = ModifierMask(rawValue: 1 << 2)
    public static let command = ModifierMask(rawValue: 1 << 3)
}

/// One keystroke that fires the global hotkey when matched. Stored as
/// a single string in UserDefaults via `serialized()` / `fromSerialized()`
/// to avoid a custom Codable container per setting.
public struct KeyCombo: Equatable, Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: ModifierMask

    public init(keyCode: UInt16, modifiers: ModifierMask) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// `"<keyCode>:<modifiersRaw>"`. Compact, human-readable in
    /// `defaults read`, won't drift across Codable revisions.
    public func serialized() -> String {
        "\(keyCode):\(modifiers.rawValue)"
    }

    public static func fromSerialized(_ string: String) -> KeyCombo? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, !parts[1].isEmpty,
              let keyCode = UInt16(parts[0]),
              let modRaw = UInt(parts[1]) else {
            return nil
        }
        return KeyCombo(keyCode: keyCode, modifiers: ModifierMask(rawValue: modRaw))
    }
}

/// Decides whether a recorded combo is safe to use as a global hotkey.
/// The rule is conservative: anything that fires from normal typing is
/// rejected. Function keys are the only "no modifier" combos allowed
/// because they aren't part of prose input.
public enum KeyComboValidator {

    public static func isValid(_ combo: KeyCombo) -> Bool {
        if KeyCodeTable.isFunctionKey(combo.keyCode) { return true }
        return !combo.modifiers.isEmpty
    }
}

/// Renders a combo to the standard macOS hotkey string ("⌃⌥⇧⌘C").
/// Modifier glyphs follow Apple's canonical order regardless of how the
/// `ModifierMask` was constructed.
public enum KeyComboFormatter {

    public static func display(_ combo: KeyCombo) -> String {
        var result = ""
        if combo.modifiers.contains(.control) { result += "⌃" }
        if combo.modifiers.contains(.option)  { result += "⌥" }
        if combo.modifiers.contains(.shift)   { result += "⇧" }
        if combo.modifiers.contains(.command) { result += "⌘" }
        result += KeyCodeTable.name(for: combo.keyCode)
        return result
    }
}

/// macOS virtual key code → display name. Values are the same as the
/// Carbon `kVK_*` constants used by `NSEvent.keyCode`. Subset that
/// covers everything a user might bind; unknown codes fall back to
/// `"Key<code>"` so the UI never blanks out.
enum KeyCodeTable {

    static func name(for code: UInt16) -> String {
        names[code] ?? "Key\(code)"
    }

    static func isFunctionKey(_ code: UInt16) -> Bool {
        functionKeys.contains(code)
    }

    private static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private static let names: [UInt16: String] = [
        // Letters
        0: "A",  11: "B", 8: "C",  2: "D",  14: "E", 3: "F",  5: "G",
        4: "H",  34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S",  17: "T", 32: "U",
        9: "V",  13: "W", 7: "X",  16: "Y", 6: "Z",
        // Numbers (top row)
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        // Function keys
        122: "F1",  120: "F2",  99: "F3",  118: "F4",  96: "F5",
        97: "F6",   98: "F7",   100: "F8", 101: "F9",  109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17",  79: "F18",  80: "F19",  90: "F20",
        // Whitespace / navigation
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab",
        53: "Esc",   51: "Delete", 117: "Forward Delete",
        116: "Page Up", 121: "Page Down", 115: "Home", 119: "End",
        123: "Left", 124: "Right", 126: "Up", 125: "Down",
    ]
}
