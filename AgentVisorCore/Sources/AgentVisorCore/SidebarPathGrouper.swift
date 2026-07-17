import Foundation

/// Row carrying everything `SidebarPathGrouper` needs. Same shape as
/// `SidebarSessionRow` plus the originating cwd so the grouper can
/// derive a project key without dragging `SessionState` into Core.
public struct SidebarPathRow: Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let title: String
    public let subtitle: String
    public let agent: AgentID
    public let needsAttention: Bool
    public let isActive: Bool
    public let lastActivity: Date
    public let cwd: String

    public var id: String { sessionId }

    public init(
        sessionId: String,
        title: String,
        subtitle: String,
        agent: AgentID,
        needsAttention: Bool,
        isActive: Bool,
        lastActivity: Date,
        cwd: String
    ) {
        self.sessionId = sessionId
        self.title = title
        self.subtitle = subtitle
        self.agent = agent
        self.needsAttention = needsAttention
        self.isActive = isActive
        self.lastActivity = lastActivity
        self.cwd = cwd
    }
}

public enum SidebarPathGroupKind: Equatable, Hashable, Sendable {
    case needsAttention
    case working
    case ready
    case recent
    case project(name: String)
    case other

    public var displayTitle: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .working: return "Working"
        case .ready: return "Ready"
        case .recent: return "Recent"
        case .project(let name): return name
        case .other: return "Other"
        }
    }
}

public struct SidebarPathGroup: Equatable, Sendable, Identifiable {
    public let kind: SidebarPathGroupKind
    public let rows: [SidebarPathRow]

    public init(kind: SidebarPathGroupKind, rows: [SidebarPathRow]) {
        self.kind = kind
        self.rows = rows
    }

    public var id: String {
        switch kind {
        case .needsAttention: return "needsAttention"
        case .working: return "working"
        case .ready: return "ready"
        case .recent: return "recent"
        case .project(let name): return "project:\(name)"
        case .other: return "other"
        }
    }

    public var displayTitle: String {
        kind.displayTitle
    }
}

/// Hybrid sidebar grouper used by the window-mode sessions list.
///
/// Layout from top to bottom:
///   1. Needs attention   — every session whose `needsAttention == true`,
///                          regardless of project. Omitted entirely when
///                          empty so the section header never appears
///                          stranded.
///   2. Project sections  — one per `cwd.lastPathComponent`, ordered by
///                          the group's most-recent activity (newer first).
///                          Each row sorts within its group by
///                          `lastActivity` desc, with `sessionId` as a
///                          stable tie-breaker.
///   3. Other              — sessions whose cwd has no usable project
///                          key (empty, root, or the user's home dir).
///                          Always pinned to the bottom regardless of
///                          how recent its rows are; that's the whole
///                          point of "Other" — it's the catch-all for
///                          stuff that doesn't belong to any project.
///
/// The grouper is pure: pass `homeDirectory` so tests don't depend on
/// the runtime user. Production callers use
/// `FileManager.default.homeDirectoryForCurrentUser.path`.
public enum SidebarPathGrouper {
    public static func group(_ rows: [SidebarPathRow], homeDirectory: String) -> [SidebarPathGroup] {
        guard !rows.isEmpty else { return [] }

        var attention: [SidebarPathRow] = []
        var byProject: [String: [SidebarPathRow]] = [:]
        var other: [SidebarPathRow] = []

        for row in rows {
            if row.needsAttention {
                attention.append(row)
                continue
            }
            if let key = projectKey(forCwd: row.cwd, homeDirectory: homeDirectory) {
                byProject[key, default: []].append(row)
            } else {
                other.append(row)
            }
        }

        let sortRows: ([SidebarPathRow]) -> [SidebarPathRow] = { input in
            input.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity {
                    return lhs.lastActivity > rhs.lastActivity
                }
                return lhs.sessionId < rhs.sessionId
            }
        }

        var built: [SidebarPathGroup] = []

        if !attention.isEmpty {
            built.append(.init(kind: .needsAttention, rows: sortRows(attention)))
        }

        // Project order = each group's most-recent activity, descending.
        let orderedProjects = byProject.keys.sorted { lhs, rhs in
            let lhsMax = byProject[lhs]?.map(\.lastActivity).max() ?? .distantPast
            let rhsMax = byProject[rhs]?.map(\.lastActivity).max() ?? .distantPast
            if lhsMax != rhsMax { return lhsMax > rhsMax }
            return lhs < rhs
        }
        for name in orderedProjects {
            let rs = sortRows(byProject[name] ?? [])
            built.append(.init(kind: .project(name: name), rows: rs))
        }

        if !other.isEmpty {
            built.append(.init(kind: .other, rows: sortRows(other)))
        }

        return built
    }

    /// Returns the project key for a cwd, or nil when the cwd doesn't
    /// belong to any identifiable project (empty, root, or the user's
    /// $HOME exactly). Standardizes trailing-slash variants.
    public static func projectKey(forCwd cwd: String, homeDirectory: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" { return nil }

        // Normalize a trailing slash so "/Users/x" and "/Users/x/" agree.
        var normalized = trimmed
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        let normalizedHome: String = {
            var h = homeDirectory
            while h.count > 1, h.hasSuffix("/") {
                h.removeLast()
            }
            return h
        }()

        if normalized == normalizedHome { return nil }

        return ProjectDisplayNamePolicy.displayName(forCwd: normalized)
    }
}
