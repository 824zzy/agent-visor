import Foundation

public struct SessionNavigatorSearchCandidate: Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let project: String
    public let source: String
    public let owner: String
    public let path: String
    public let sortDate: Date

    public init(
        sessionID: String,
        title: String,
        project: String,
        source: String,
        owner: String,
        path: String,
        sortDate: Date
    ) {
        self.sessionID = sessionID
        self.title = title
        self.project = project
        self.source = source
        self.owner = owner
        self.path = path
        self.sortDate = sortDate
    }
}

public struct SessionNavigatorSearchSelection: Equatable, Sendable {
    public let isSearching: Bool
    public let orderedSessionIDs: [String]

    public init(isSearching: Bool, orderedSessionIDs: [String]) {
        self.isSearching = isSearching
        self.orderedSessionIDs = orderedSessionIDs
    }
}

public enum SessionNavigatorSearchPolicy {
    public static func select(
        overflowSessionIDs: [String],
        allCandidates: [SessionNavigatorSearchCandidate],
        query: String
    ) -> SessionNavigatorSearchSelection {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let orderedSessionIDs: [String]
        if isSearching {
            orderedSessionIDs = SessionBrowserPolicy.select(
                candidates: allCandidates.map { candidate in
                    SessionBrowserCandidate(
                        sessionId: candidate.sessionID,
                        title: candidate.title,
                        preview: "",
                        project: candidate.project,
                        source: candidate.source,
                        owner: candidate.owner,
                        path: candidate.path,
                        section: .recent,
                        sortDate: candidate.sortDate,
                        isHidden: false,
                        isArchived: false
                    )
                },
                query: query
            ).orderedSessionIds
        } else {
            orderedSessionIDs = overflowSessionIDs
        }
        return SessionNavigatorSearchSelection(
            isSearching: isSearching,
            orderedSessionIDs: orderedSessionIDs
        )
    }
}
