import Foundation

public enum PillSurfaceRole: Equatable, Sendable {
    case active
    case recentShortcut
    case hidden
}

public enum PillSurfacePhase: Equatable, Sendable {
    case needsAttention
    case ready
    case working
    case idle
    case ended
}

public struct PillSurfaceCandidate: Equatable, Sendable {
    public let id: String
    public let phase: PillSurfacePhase
    public let sortDate: Date
    public let statusDate: Date?
    public let navigationDate: Date?
    public let readyAcknowledgedAt: Date?
    public let isHidden: Bool
    public let isTitleless: Bool

    public init(
        id: String,
        phase: PillSurfacePhase,
        sortDate: Date,
        statusDate: Date? = nil,
        navigationDate: Date?,
        isHidden: Bool,
        isTitleless: Bool,
        readyAcknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.phase = phase
        self.sortDate = sortDate
        self.statusDate = statusDate
        self.navigationDate = navigationDate
        self.readyAcknowledgedAt = readyAcknowledgedAt
        self.isHidden = isHidden
        self.isTitleless = isTitleless
    }
}

public struct PillSurfaceSelection: Equatable, Sendable {
    public let orderedActiveIds: [String]
    public let orderedRecentShortcutIds: [String]

    public init(orderedActiveIds: [String], orderedRecentShortcutIds: [String]) {
        self.orderedActiveIds = orderedActiveIds
        self.orderedRecentShortcutIds = orderedRecentShortcutIds
    }

    public var orderedVisibleIds: [String] {
        orderedActiveIds + orderedRecentShortcutIds
    }
}

public enum PillSurfacePolicy {
    private enum ActiveTier: Int {
        case needsAttention
        case prominentReady
        case working
        case acknowledgedReady
        case idle
        case ended
    }

    public static let defaultRecentActivityWindow: TimeInterval = 30 * 60
    public static let defaultRecentShortcutLimit = Int.max

    public static func role(
        for candidate: PillSurfaceCandidate,
        now: Date,
        recentActivityWindow: TimeInterval = defaultRecentActivityWindow
    ) -> PillSurfaceRole {
        if candidate.isHidden || candidate.isTitleless || candidate.phase == .ended {
            return .hidden
        }

        switch candidate.phase {
        case .needsAttention, .ready, .working:
            return .active
        case .idle:
            return .recentShortcut
        case .ended:
            return .hidden
        }
    }

    public static func select(
        candidates: [PillSurfaceCandidate],
        now: Date,
        recentActivityWindow: TimeInterval = defaultRecentActivityWindow,
        recentShortcutLimit: Int = defaultRecentShortcutLimit
    ) -> PillSurfaceSelection {
        var active: [PillSurfaceCandidate] = []
        var recent: [PillSurfaceCandidate] = []

        for candidate in candidates {
            switch role(for: candidate, now: now, recentActivityWindow: recentActivityWindow) {
            case .active:
                active.append(candidate)
            case .recentShortcut:
                recent.append(candidate)
            case .hidden:
                break
            }
        }

        let orderedActive = active.sorted { activePrecedes($0, $1, now: now) }.map(\.id)
        let orderedRecent = Array(recent.sorted(by: recentShortcutPrecedes).prefix(max(0, recentShortcutLimit))).map(\.id)

        return PillSurfaceSelection(
            orderedActiveIds: orderedActive,
            orderedRecentShortcutIds: orderedRecent
        )
    }

    private static func activePrecedes(
        _ lhs: PillSurfaceCandidate,
        _ rhs: PillSurfaceCandidate,
        now: Date
    ) -> Bool {
        let lhsPriority = activePriority(lhs, now: now)
        let rhsPriority = activePriority(rhs, now: now)
        if lhsPriority != rhsPriority { return lhsPriority.rawValue < rhsPriority.rawValue }

        let lhsStatusDate = lhs.statusDate ?? lhs.sortDate
        let rhsStatusDate = rhs.statusDate ?? rhs.sortDate
        if lhsStatusDate != rhsStatusDate { return lhsStatusDate > rhsStatusDate }
        return lhs.id < rhs.id
    }

    private static func recentShortcutPrecedes(_ lhs: PillSurfaceCandidate, _ rhs: PillSurfaceCandidate) -> Bool {
        let lhsDate = lhs.navigationDate ?? lhs.sortDate
        let rhsDate = rhs.navigationDate ?? rhs.sortDate
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id < rhs.id
    }

    private static func activePriority(
        _ candidate: PillSurfaceCandidate,
        now: Date
    ) -> ActiveTier {
        switch candidate.phase {
        case .needsAttention: return .needsAttention
        case .ready:
            let phaseDate = candidate.statusDate ?? candidate.sortDate
            return ReadyAttentionPolicy.shouldRemainProminent(
                phaseChangedAt: phaseDate,
                acknowledgedAt: candidate.readyAcknowledgedAt,
                now: now
            ) ? .prominentReady : .acknowledgedReady
        case .working: return .working
        case .idle:    return .idle
        case .ended:   return .ended
        }
    }
}
