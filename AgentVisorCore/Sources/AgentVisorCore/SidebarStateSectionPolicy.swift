import Foundation

public enum SidebarStateSectionKind: String, CaseIterable, Sendable {
    case needsAttention
    case working
    case ready
    case recent

    public var displayTitle: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .working: return "Working"
        case .ready: return "Ready"
        case .recent: return "Recent"
        }
    }
}

public struct SidebarStateSectionCandidate: Equatable, Sendable {
    public let sessionId: String
    public let section: SidebarStateSectionKind
    public let sortDate: Date

    public init(
        sessionId: String,
        section: SidebarStateSectionKind,
        sortDate: Date
    ) {
        self.sessionId = sessionId
        self.section = section
        self.sortDate = sortDate
    }
}

public struct SidebarStateSectionGroup: Equatable, Sendable {
    public let kind: SidebarStateSectionKind
    public let rows: [SidebarStateSectionCandidate]

    public init(kind: SidebarStateSectionKind, rows: [SidebarStateSectionCandidate]) {
        self.kind = kind
        self.rows = rows
    }
}

public enum SidebarStateSectionPolicy {
    public static let orderedSections: [SidebarStateSectionKind] = [
        .needsAttention,
        .ready,
        .working,
        .recent,
    ]

    public static func group(_ candidates: [SidebarStateSectionCandidate]) -> [SidebarStateSectionGroup] {
        let bySection = Dictionary(grouping: candidates, by: \.section)
        return orderedSections.compactMap { section in
            guard let rows = bySection[section], !rows.isEmpty else { return nil }
            return SidebarStateSectionGroup(
                kind: section,
                rows: rows.sorted(by: rowPrecedes)
            )
        }
    }

    public static func visibleIds(from groups: [SidebarStateSectionGroup]) -> [String] {
        groups.flatMap { $0.rows.map(\.sessionId) }
    }

    private static func rowPrecedes(
        _ lhs: SidebarStateSectionCandidate,
        _ rhs: SidebarStateSectionCandidate
    ) -> Bool {
        if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
        return lhs.sessionId < rhs.sessionId
    }
}
