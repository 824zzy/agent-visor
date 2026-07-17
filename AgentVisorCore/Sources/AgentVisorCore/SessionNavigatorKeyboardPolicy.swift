import Foundation

public enum SessionNavigatorKeyboardEvent: Equatable, Sendable {
    case opened
    case move(offset: Int)
    case activate(modifierIntent: PillClickModifierIntent)
    case focusSearch
    case insertText(String)
    case deleteBackward
    case dismiss
}

public enum SessionNavigatorKeyboardInputPolicy {
    public static func event(
        keyCode: UInt16,
        modifiers: ModifierMask,
        text: String? = nil
    ) -> SessionNavigatorKeyboardEvent? {
        switch (keyCode, modifiers) {
        case (125, []):
            return .move(offset: 1)
        case (126, []):
            return .move(offset: -1)
        case (36, []), (76, []):
            return .activate(modifierIntent: .standard)
        case (36, .option), (76, .option):
            return .activate(modifierIntent: .forceAgentVisor)
        case (3, .command):
            return .focusSearch
        case (51, []):
            return .deleteBackward
        case (53, []):
            return .dismiss
        default:
            guard modifiers.subtracting(.shift).isEmpty,
                  let text,
                  !text.isEmpty,
                  text.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            return .insertText(text)
        }
    }
}

public enum SessionNavigatorKeyboardAction: Equatable, Sendable {
    case none
    case open(sessionID: String, modifierIntent: PillClickModifierIntent)
    case focusSearch
    case dismiss
}

public struct SessionNavigatorKeyboardDecision: Equatable, Sendable {
    public let cursorSessionID: String?
    public let query: String
    public let action: SessionNavigatorKeyboardAction

    public init(
        cursorSessionID: String?,
        query: String,
        action: SessionNavigatorKeyboardAction
    ) {
        self.cursorSessionID = cursorSessionID
        self.query = query
        self.action = action
    }
}

public enum SessionNavigatorKeyboardPolicy {
    public static func reduce(
        currentCursorID: String?,
        visibleSessionIDs: [String],
        query: String = "",
        event: SessionNavigatorKeyboardEvent
    ) -> SessionNavigatorKeyboardDecision {
        switch event {
        case .opened:
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: visibleSessionIDs.first,
                query: query,
                action: .none
            )
        case .move(let offset):
            guard let firstID = visibleSessionIDs.first else {
                return SessionNavigatorKeyboardDecision(
                    cursorSessionID: nil,
                    query: query,
                    action: .none
                )
            }
            guard let currentCursorID,
                  let currentIndex = visibleSessionIDs.firstIndex(of: currentCursorID) else {
                return SessionNavigatorKeyboardDecision(
                    cursorSessionID: firstID,
                    query: query,
                    action: .none
                )
            }
            let nextIndex = min(
                max(currentIndex + offset, 0),
                visibleSessionIDs.count - 1
            )
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: visibleSessionIDs[nextIndex],
                query: query,
                action: .none
            )
        case .activate(let modifierIntent):
            let cursorSessionID = currentCursorID.flatMap { currentID in
                visibleSessionIDs.contains(currentID) ? currentID : nil
            } ?? visibleSessionIDs.first
            let action = cursorSessionID.map {
                SessionNavigatorKeyboardAction.open(
                    sessionID: $0,
                    modifierIntent: modifierIntent
                )
            } ?? .none
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: cursorSessionID,
                query: query,
                action: action
            )
        case .focusSearch:
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: currentCursorID,
                query: query,
                action: .focusSearch
            )
        case .insertText(let text):
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: currentCursorID,
                query: query + text,
                action: .none
            )
        case .deleteBackward:
            var updatedQuery = query
            if !updatedQuery.isEmpty {
                updatedQuery.removeLast()
            }
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: currentCursorID,
                query: updatedQuery,
                action: .none
            )
        case .dismiss:
            if !query.isEmpty {
                return SessionNavigatorKeyboardDecision(
                    cursorSessionID: currentCursorID,
                    query: "",
                    action: .none
                )
            }
            return SessionNavigatorKeyboardDecision(
                cursorSessionID: currentCursorID,
                query: query,
                action: .dismiss
            )
        }
    }
}
