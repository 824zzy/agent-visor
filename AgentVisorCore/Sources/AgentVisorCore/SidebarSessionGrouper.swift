import Foundation

/// Pure presentation model for one row in the window-mode sessions sidebar.
/// Built from `SessionState` at the call site so this layer stays testable
/// without dragging the AppKit/Combine pieces of the host into Core.
public struct SidebarSessionRow: Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let title: String
    public let subtitle: String
    public let agent: AgentID
    public let needsAttention: Bool
    public let isActive: Bool
    public let lastActivity: Date

    public var id: String { sessionId }

    public init(
        sessionId: String,
        title: String,
        subtitle: String,
        agent: AgentID,
        needsAttention: Bool,
        isActive: Bool,
        lastActivity: Date
    ) {
        self.sessionId = sessionId
        self.title = title
        self.subtitle = subtitle
        self.agent = agent
        self.needsAttention = needsAttention
        self.isActive = isActive
        self.lastActivity = lastActivity
    }
}

public enum SidebarGroupKind: String, Sendable, CaseIterable {
    case needsAttention
    case active
    case recent

    public var displayTitle: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .active:         return "Active"
        case .recent:         return "Recent"
        }
    }
}

public struct SidebarSessionGroup: Equatable, Sendable, Identifiable {
    public let kind: SidebarGroupKind
    public let rows: [SidebarSessionRow]

    public var id: String { kind.rawValue }

    public init(kind: SidebarGroupKind, rows: [SidebarSessionRow]) {
        self.kind = kind
        self.rows = rows
    }
}

/// Bins `SidebarSessionRow`s into the three sidebar buckets and orders
/// rows within each bucket. Pure function so the logic is testable
/// independent of SessionStore.
public enum SidebarSessionGrouper {
    public static func group(_ rows: [SidebarSessionRow]) -> [SidebarSessionGroup] {
        var attention: [SidebarSessionRow] = []
        var active: [SidebarSessionRow] = []
        var recent: [SidebarSessionRow] = []

        for row in rows {
            if row.needsAttention {
                attention.append(row)
            } else if row.isActive {
                active.append(row)
            } else {
                recent.append(row)
            }
        }

        let sort: ([SidebarSessionRow]) -> [SidebarSessionRow] = { input in
            input.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity {
                    return lhs.lastActivity > rhs.lastActivity
                }
                return lhs.sessionId < rhs.sessionId
            }
        }

        var result: [SidebarSessionGroup] = []
        if !attention.isEmpty {
            result.append(.init(kind: .needsAttention, rows: sort(attention)))
        }
        if !active.isEmpty {
            result.append(.init(kind: .active, rows: sort(active)))
        }
        if !recent.isEmpty {
            result.append(.init(kind: .recent, rows: sort(recent)))
        }
        return result
    }
}
