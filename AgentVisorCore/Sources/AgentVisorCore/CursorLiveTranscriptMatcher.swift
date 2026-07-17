import Foundation

public enum CursorLiveTranscriptMatcher {
    public struct Process: Equatable, Sendable {
        public let id: String
        public let cwd: String

        public init(id: String, cwd: String) {
            self.id = id
            self.cwd = cwd
        }
    }

    public struct Transcript: Equatable, Sendable {
        public let sessionId: String
        public let projectKey: String
        public let mtime: TimeInterval

        public init(sessionId: String, projectKey: String, mtime: TimeInterval) {
            self.sessionId = sessionId
            self.projectKey = projectKey
            self.mtime = mtime
        }
    }

    public struct Match: Equatable, Sendable {
        public let process: Process
        public let transcript: Transcript

        public init(process: Process, transcript: Transcript) {
            self.process = process
            self.transcript = transcript
        }
    }

    public static func match(
        processes: [Process],
        transcripts: [Transcript]
    ) -> [Match] {
        var byProject = Dictionary(grouping: transcripts.sorted { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.sessionId < rhs.sessionId
        }, by: \.projectKey)
        var consumedSessionIds = Set<String>()
        var matches: [Match] = []

        for process in processes {
            let key = CursorProjectKeyEncoder.projectKey(forCwd: process.cwd)
            guard var candidates = byProject[key] else { continue }

            while let transcript = candidates.first {
                candidates.removeFirst()
                if consumedSessionIds.insert(transcript.sessionId).inserted {
                    matches.append(Match(process: process, transcript: transcript))
                    break
                }
            }
            byProject[key] = candidates
        }

        return matches
    }
}
