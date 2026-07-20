import Foundation

public enum SessionBrowserSection: Int, CaseIterable, Equatable, Sendable {
    case needsAttention
    case ready
    case working
    case recent

    public var displayTitle: String {
        switch self {
        case .needsAttention: return "Needs you"
        case .ready: return "Ready to continue"
        case .working: return "In progress"
        case .recent: return "History"
        }
    }
}

public struct SessionBrowserCandidate: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let preview: String
    public let project: String
    public let source: String
    public let owner: String
    public let path: String
    public let section: SessionBrowserSection
    public let sortDate: Date
    public let isHidden: Bool
    public let isArchived: Bool

    public init(
        sessionId: String,
        title: String,
        preview: String,
        project: String,
        source: String,
        owner: String,
        path: String,
        section: SessionBrowserSection,
        sortDate: Date,
        isHidden: Bool,
        isArchived: Bool
    ) {
        self.sessionId = sessionId
        self.title = title
        self.preview = preview
        self.project = project
        self.source = source
        self.owner = owner
        self.path = path
        self.section = section
        self.sortDate = sortDate
        self.isHidden = isHidden
        self.isArchived = isArchived
    }
}

public struct SessionBrowserGroup: Equatable, Sendable {
    public let section: SessionBrowserSection
    public let sessionIds: [String]

    public init(section: SessionBrowserSection, sessionIds: [String]) {
        self.section = section
        self.sessionIds = sessionIds
    }
}

public struct SessionBrowserSelection: Equatable, Sendable {
    public let isSearching: Bool
    public let groups: [SessionBrowserGroup]
    public let orderedSessionIds: [String]

    public init(
        isSearching: Bool,
        groups: [SessionBrowserGroup],
        orderedSessionIds: [String]
    ) {
        self.isSearching = isSearching
        self.groups = groups
        self.orderedSessionIds = orderedSessionIds
    }
}

public enum SessionBrowserPolicy {
    public static func select(
        candidates: [SessionBrowserCandidate],
        query: String
    ) -> SessionBrowserSelection {
        let visible = candidates.filter {
            !$0.isHidden && !$0.isArchived && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let normalizedQuery = normalized(query)
        if !normalizedQuery.isEmpty {
            let terms = normalizedQuery.split(separator: " ").map(String.init)
            let matches = visible.compactMap { candidate -> (SessionBrowserCandidate, Int)? in
                guard let score = searchScore(
                    candidate,
                    normalizedQuery: normalizedQuery,
                    terms: terms
                ) else { return nil }
                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return rowComesBefore(lhs.0, rhs.0)
            }
            .map { $0.0.sessionId }

            return SessionBrowserSelection(
                isSearching: true,
                groups: [],
                orderedSessionIds: matches
            )
        }

        let groups = SessionBrowserSection.allCases.compactMap { section -> SessionBrowserGroup? in
            let ids = visible
                .filter { $0.section == section }
                .sorted(by: rowComesBefore)
                .map(\.sessionId)
            return ids.isEmpty ? nil : SessionBrowserGroup(section: section, sessionIds: ids)
        }
        return SessionBrowserSelection(
            isSearching: false,
            groups: groups,
            orderedSessionIds: groups.flatMap(\.sessionIds)
        )
    }

    private static func searchScore(
        _ candidate: SessionBrowserCandidate,
        normalizedQuery: String,
        terms: [String]
    ) -> Int? {
        let title = normalized(candidate.title)
        let project = normalized(candidate.project)
        let source = normalized(candidate.source)
        let owner = normalized(candidate.owner)
        let preview = normalized(candidate.preview)
        let path = normalized(candidate.path)
        let searchable = [title, project, source, owner, preview, path].joined(separator: " ")
        guard terms.allSatisfy(searchable.contains) else { return nil }

        if title == normalizedQuery { return 1_000 }
        if title.hasPrefix(normalizedQuery) { return 800 }
        if title.contains(normalizedQuery) { return 650 }
        if project == normalizedQuery { return 500 }
        if project.contains(normalizedQuery) { return 450 }
        if source.contains(normalizedQuery) || owner.contains(normalizedQuery) { return 350 }
        if preview.contains(normalizedQuery) { return 250 }
        if path.contains(normalizedQuery) { return 200 }
        return 100
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let separated = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(separated)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func rowComesBefore(
        _ lhs: SessionBrowserCandidate,
        _ rhs: SessionBrowserCandidate
    ) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }
        return lhs.sessionId < rhs.sessionId
    }
}
