import Foundation

public struct CodexProcessCandidate: Equatable, Sendable {
    public let pid: Int
    public let tty: String?
    public let cwd: String

    public init(pid: Int, tty: String?, cwd: String) {
        self.pid = pid
        self.tty = tty
        self.cwd = cwd
    }
}

public struct CodexThreadCandidate: Equatable, Sendable {
    public let id: String
    public let rolloutPath: String
    public let cwd: String
    public let title: String?
    public let updatedAt: Int
    public let archived: Bool
    /// Codex `threads.source` column. Distinguishes GUI threads
    /// (`vscode`), terminal threads (`cli` / `exec`), and subagent
    /// threads (a JSON blob containing `subagent`, e.g.
    /// `{"subagent":{"other":"guardian"}}`). Defaults to empty so
    /// older call sites that don't read the column still compile.
    public let source: String
    /// Unix mtime of the thread's rollout JSONL, or nil when the file
    /// is missing/unreadable. Lets the pure selector treat an archived
    /// thread as "still running" when its rollout is being written
    /// right now (Codex marks background-research threads archived the
    /// instant they start, yet keeps appending turns). nil ⇒ liveness
    /// can't be confirmed, so the archived thread is excluded.
    public let rolloutModifiedAt: Int?

    /// Codex moves a user-archived rollout into this dedicated directory.
    /// That relocation is a stronger close signal than `archived` alone:
    /// background research can be marked archived while it is still writing,
    /// but its rollout remains in the normal sessions tree.
    public var isExplicitlyArchived: Bool {
        URL(fileURLWithPath: rolloutPath)
            .standardizedFileURL
            .pathComponents
            .contains("archived_sessions")
    }

    public init(
        id: String,
        rolloutPath: String,
        cwd: String,
        title: String?,
        updatedAt: Int,
        archived: Bool,
        source: String = "",
        rolloutModifiedAt: Int? = nil
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.archived = archived
        self.source = source
        self.rolloutModifiedAt = rolloutModifiedAt
    }
}

public struct CodexLiveThreadMatch: Equatable, Sendable {
    public let thread: CodexThreadCandidate
    public let process: CodexProcessCandidate

    public init(thread: CodexThreadCandidate, process: CodexProcessCandidate) {
        self.thread = thread
        self.process = process
    }
}

public enum CodexLiveThreadMatcher {
    public static func matchLiveThreads(
        processes: [CodexProcessCandidate],
        threads: [CodexThreadCandidate]
    ) -> [CodexLiveThreadMatch] {
        var matches: [CodexLiveThreadMatch] = []
        var claimedThreadIds = Set<String>()

        for process in processes {
            let processCwd = normalize(process.cwd)
            let candidates = threads
                .filter {
                    !$0.archived
                        && !$0.isExplicitlyArchived
                        && $0.source == "cli"
                        && normalize($0.cwd) == processCwd
                }
                .sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.id < rhs.id
                }

            guard let best = candidates.first else { continue }
            let tied = candidates.dropFirst().contains { $0.updatedAt == best.updatedAt }
            guard !tied, !claimedThreadIds.contains(best.id) else { continue }

            claimedThreadIds.insert(best.id)
            matches.append(CodexLiveThreadMatch(thread: best, process: process))
        }

        return matches
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
