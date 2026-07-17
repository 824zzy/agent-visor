public enum SessionBrowserListElement: Equatable, Sendable, Identifiable {
    case searchResults(count: Int)
    case section(SessionBrowserSection, count: Int)
    case session(String, section: SessionBrowserSection?, isKeyboardCursor: Bool)

    public var id: String {
        switch self {
        case .searchResults:
            return "header:results"
        case .section(let section, _):
            return "header:section:\(section.rawValue)"
        case .session(let sessionID, _, _):
            return "session:\(sessionID)"
        }
    }
}

public enum SessionBrowserListPresentation {
    public static func elements(
        for selection: SessionBrowserSelection,
        keyboardCursorSessionID: String?
    ) -> [SessionBrowserListElement] {
        if selection.isSearching {
            return [.searchResults(count: selection.orderedSessionIds.count)]
                + selection.orderedSessionIds.map { sessionID in
                    .session(
                        sessionID,
                        section: nil,
                        isKeyboardCursor: sessionID == keyboardCursorSessionID
                    )
                }
        }

        return selection.groups.flatMap { group in
            [.section(group.section, count: group.sessionIds.count)]
                + group.sessionIds.map { sessionID in
                    .session(
                        sessionID,
                        section: group.section,
                        isKeyboardCursor: sessionID == keyboardCursorSessionID
                    )
                }
        }
    }
}
