import Foundation

public struct PiProcessCandidate: Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let startedAt: Date
    public let tty: String?

    public init(id: String, cwd: String, startedAt: Date, tty: String?) {
        self.id = id
        self.cwd = cwd
        self.startedAt = startedAt
        self.tty = tty
    }
}

public struct PiSessionCandidate: Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let createdAt: Date

    public init(id: String, cwd: String, createdAt: Date) {
        self.id = id
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

public struct PiProcessSessionMatch: Equatable, Sendable {
    public let process: PiProcessCandidate
    public let session: PiSessionCandidate

    public init(process: PiProcessCandidate, session: PiSessionCandidate) {
        self.process = process
        self.session = session
    }
}

public enum PiProcessSessionMatcher {
    public static func match(
        processes: [PiProcessCandidate],
        sessions: [PiSessionCandidate],
        tolerance: TimeInterval
    ) -> [PiProcessSessionMatch] {
        var usedSessionIDs: Set<String> = []
        var matches: [PiProcessSessionMatch] = []

        for process in processes {
            let processCwd = normalized(process.cwd)
            let candidate = sessions
                .filter {
                    !usedSessionIDs.contains($0.id)
                        && normalized($0.cwd) == processCwd
                        && abs($0.createdAt.timeIntervalSince(process.startedAt)) <= tolerance
                }
                .min {
                    let lhsDistance = abs($0.createdAt.timeIntervalSince(process.startedAt))
                    let rhsDistance = abs($1.createdAt.timeIntervalSince(process.startedAt))
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    return $0.id < $1.id
                }

            guard let candidate else { continue }
            usedSessionIDs.insert(candidate.id)
            matches.append(PiProcessSessionMatch(process: process, session: candidate))
        }
        return matches
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
