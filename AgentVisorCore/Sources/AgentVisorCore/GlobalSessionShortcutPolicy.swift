import Foundation

public enum SessionShortcutModifierFamily: String, CaseIterable, Sendable {
    case off
    case controlCommand
    case optionCommand
    case controlOptionCommand

    public var modifiers: ModifierMask {
        switch self {
        case .off: return []
        case .controlCommand: return [.control, .command]
        case .optionCommand: return [.option, .command]
        case .controlOptionCommand: return [.control, .option, .command]
        }
    }

    public var displayLabel: String {
        modifierGlyphs.map { "\($0)1-9" } ?? "Off"
    }

    var modifierGlyphs: String? {
        switch self {
        case .off: return nil
        case .controlCommand: return "⌃⌘"
        case .optionCommand: return "⌥⌘"
        case .controlOptionCommand: return "⌃⌥⌘"
        }
    }
}

public enum GlobalSessionShortcutAction: Equatable, Sendable {
    case navigate(position: Int)
    case toggleOverflow
}

public struct GlobalSessionRegisteredHotKey: Equatable, Sendable {
    public let id: UInt32
    public let digit: Int
    public let keyCode: UInt32

    public init(id: UInt32, digit: Int, keyCode: UInt32) {
        self.id = id
        self.digit = digit
        self.keyCode = keyCode
    }
}

public enum GlobalSessionOverflowAction: Equatable, Sendable {
    case open
    case close
    case ignore
}

public enum GlobalSessionShortcutPolicy {
    public static let registeredHotKeys: [GlobalSessionRegisteredHotKey] = [
        .init(id: 0, digit: 0, keyCode: 29),
        .init(id: 1, digit: 1, keyCode: 18),
        .init(id: 2, digit: 2, keyCode: 19),
        .init(id: 3, digit: 3, keyCode: 20),
        .init(id: 4, digit: 4, keyCode: 21),
        .init(id: 5, digit: 5, keyCode: 23),
        .init(id: 6, digit: 6, keyCode: 22),
        .init(id: 7, digit: 7, keyCode: 26),
        .init(id: 8, digit: 8, keyCode: 28),
        .init(id: 9, digit: 9, keyCode: 25),
    ]

    public static func action(forKeyCharacter character: String) -> GlobalSessionShortcutAction? {
        if character == "0" {
            return .toggleOverflow
        }
        return SessionHotkeyMatcher.position(forKeyCharacter: character).map {
            .navigate(position: $0)
        }
    }

    public static func action(forRegisteredHotKeyID id: UInt32) -> GlobalSessionShortcutAction? {
        guard let digit = registeredHotKeys.first(where: { $0.id == id })?.digit else { return nil }
        return digit == 0 ? .toggleOverflow : .navigate(position: digit - 1)
    }

    public static func overflowAction(
        isPresented: Bool,
        hasOverflow: Bool
    ) -> GlobalSessionOverflowAction {
        if isPresented {
            return .close
        }
        return hasOverflow ? .open : .ignore
    }

    public static func displayLabel(
        forPosition position: Int,
        family: SessionShortcutModifierFamily
    ) -> String? {
        guard (1...9).contains(position), let glyphs = family.modifierGlyphs else { return nil }
        return "\(glyphs)\(position)"
    }

    public static func isArmed(
        pressedModifiers: ModifierMask,
        family: SessionShortcutModifierFamily
    ) -> Bool {
        family != .off && pressedModifiers == family.modifiers
    }
}

public struct GlobalSessionShortcutSnapshot: Equatable, Sendable {
    private let orderedSessionIDs: [String]

    public init(
        leftVisibleSessionIDs: [String],
        rightVisibleSessionIDs: [String]
    ) {
        orderedSessionIDs = Array((leftVisibleSessionIDs + rightVisibleSessionIDs).prefix(9))
    }

    public func targetSessionID(forPosition position: Int) -> String? {
        guard orderedSessionIDs.indices.contains(position) else { return nil }
        return orderedSessionIDs[position]
    }

    public func displayPosition(forSessionID sessionID: String) -> Int? {
        orderedSessionIDs.firstIndex(of: sessionID).map { $0 + 1 }
    }
}
