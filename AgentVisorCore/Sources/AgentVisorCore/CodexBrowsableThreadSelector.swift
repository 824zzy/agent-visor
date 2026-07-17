import Foundation

public enum CodexBrowsableThreadSelector {
    public static func browsableThreads(
        _ candidates: [CodexThreadCandidate]
    ) -> [CodexThreadCandidate] {
        candidates
            .filter { thread in
                !thread.archived
                    && !thread.isExplicitlyArchived
                    && CodexActiveThreadSelector.isInteractiveGUISource(thread.source)
                    && !CodexActiveThreadSelector.isIgnoredObserverCwd(thread.cwd)
                    && thread.rolloutModifiedAt != nil
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
    }
}
