public enum SessionBrowserInteractionEvent: Equatable, Sendable {
    case keyboardMove(offset: Int)
    case backgroundResultsChanged
    case queryResultsChanged
}

public struct SessionBrowserInteractionDecision: Equatable, Sendable {
    public let cursorSessionID: String?
    public let revealSessionID: String?

    public init(cursorSessionID: String?, revealSessionID: String?) {
        self.cursorSessionID = cursorSessionID
        self.revealSessionID = revealSessionID
    }
}

public enum SessionBrowserInteractionPolicy {
    public static func reduce(
        currentCursorID: String?,
        visibleSessionIDs: [String],
        event: SessionBrowserInteractionEvent
    ) -> SessionBrowserInteractionDecision {
        guard !visibleSessionIDs.isEmpty else {
            return SessionBrowserInteractionDecision(
                cursorSessionID: nil,
                revealSessionID: nil
            )
        }

        switch event {
        case .keyboardMove(let offset):
            let nextID: String
            if let currentCursorID,
               let index = visibleSessionIDs.firstIndex(of: currentCursorID) {
                let count = visibleSessionIDs.count
                let wrappedIndex = ((index + offset) % count + count) % count
                nextID = visibleSessionIDs[wrappedIndex]
            } else {
                nextID = visibleSessionIDs[0]
            }
            return SessionBrowserInteractionDecision(
                cursorSessionID: nextID,
                revealSessionID: nextID
            )
        case .backgroundResultsChanged:
            let nextID = currentCursorID.flatMap {
                visibleSessionIDs.contains($0) ? $0 : nil
            } ?? visibleSessionIDs[0]
            return SessionBrowserInteractionDecision(
                cursorSessionID: nextID,
                revealSessionID: nil
            )
        case .queryResultsChanged:
            let nextID = visibleSessionIDs[0]
            return SessionBrowserInteractionDecision(
                cursorSessionID: nextID,
                revealSessionID: nextID
            )
        }
    }
}
