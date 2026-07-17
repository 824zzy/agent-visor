import Foundation

public struct CodexDiscoverableThreadKey: Equatable, Hashable, Sendable {
    public let id: String
    public let source: String
    public let cwd: String

    public init(id: String, source: String, cwd: String) {
        self.id = id
        self.source = source
        self.cwd = cwd
    }
}

public struct CodexThreadDiscoverySnapshot: Equatable, Sendable {
    public let discoverableThreadKeys: Set<CodexDiscoverableThreadKey>
    public let activeGUIThreadIds: Set<String>

    public init(
        discoverableThreadKeys: Set<CodexDiscoverableThreadKey>,
        activeGUIThreadIds: Set<String>
    ) {
        self.discoverableThreadKeys = discoverableThreadKeys
        self.activeGUIThreadIds = activeGUIThreadIds
    }

    public static func make(
        candidates: [CodexThreadCandidate],
        now: Int,
        windowSeconds: Int = CodexActiveThreadSelector.defaultWindowSeconds
    ) -> CodexThreadDiscoverySnapshot {
        let activeGUIThreadIds = Set(
            CodexActiveThreadSelector.activeThreads(
                candidates: candidates,
                now: now,
                windowSeconds: windowSeconds
            ).map(\.id)
        )
        let keys = candidates.compactMap { thread -> CodexDiscoverableThreadKey? in
            // GUI threads — including running-archived ones — are governed by
            // `activeGUIThreadIds` (the selector already applied the
            // archived+fresh-rollout rule). The terminal/CLI path stays
            // non-archived: archive is a definitive close signal there.
            let isActiveGUI = activeGUIThreadIds.contains(thread.id)
            let isLiveTerminalCandidate = thread.source == "cli"
                && !thread.archived
                && !thread.isExplicitlyArchived
            guard isActiveGUI || isLiveTerminalCandidate else { return nil }
            return CodexDiscoverableThreadKey(
                id: thread.id,
                source: thread.source,
                cwd: URL(fileURLWithPath: thread.cwd).standardizedFileURL.path
            )
        }
        return CodexThreadDiscoverySnapshot(
            discoverableThreadKeys: Set(keys),
            activeGUIThreadIds: activeGUIThreadIds
        )
    }

    public func requiresRediscovery(comparedTo previous: CodexThreadDiscoverySnapshot?) -> Bool {
        guard let previous else { return true }
        return self != previous
    }
}
