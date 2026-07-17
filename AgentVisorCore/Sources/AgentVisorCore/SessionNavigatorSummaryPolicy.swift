import Foundation

public struct SessionNavigatorSummary: Equatable, Sendable {
    public let needsAttention: Int
    public let ready: Int
    public let working: Int
    public let recent: Int

    public var total: Int {
        needsAttention + ready + working + recent
    }

    public init(
        needsAttention: Int,
        ready: Int,
        working: Int,
        recent: Int
    ) {
        self.needsAttention = max(0, needsAttention)
        self.ready = max(0, ready)
        self.working = max(0, working)
        self.recent = max(0, recent)
    }
}

public enum SessionNavigatorSummaryPolicy {
    public static let overflowTitle = "More Sessions"
    public static let searchTitle = "Search Sessions"
    public static let openBrowserLabel = "Open Agent Sessions"
    public static let settingsLabel = "Settings..."

    public static func summary(
        sectionCounts: [SidebarStateSectionKind: Int]
    ) -> SessionNavigatorSummary {
        SessionNavigatorSummary(
            needsAttention: sectionCounts[.needsAttention] ?? 0,
            ready: sectionCounts[.ready] ?? 0,
            working: sectionCounts[.working] ?? 0,
            recent: sectionCounts[.recent] ?? 0
        )
    }

    public static func headerText(for summary: SessionNavigatorSummary) -> String {
        var parts = [
            "\(summary.needsAttention) attention",
        ]
        if summary.ready > 0 {
            parts.append("\(summary.ready) ready")
        }
        parts.append("\(summary.working) working")
        parts.append("\(summary.recent) recent")
        return parts.joined(separator: " · ")
    }

    public static func searchPlaceholder(totalSessionCount: Int) -> String {
        let count = max(0, totalSessionCount)
        return "Search all \(count) \(count == 1 ? "session" : "sessions")"
    }

    public static func searchHeaderText(
        matchCount: Int,
        totalSessionCount: Int
    ) -> String {
        let matches = max(0, matchCount)
        let total = max(0, totalSessionCount)
        let matchLabel = matches == 1 ? "match" : "matches"
        let sessionLabel = total == 1 ? "session" : "sessions"
        return "\(matches) \(matchLabel) · \(total) \(sessionLabel)"
    }
}
