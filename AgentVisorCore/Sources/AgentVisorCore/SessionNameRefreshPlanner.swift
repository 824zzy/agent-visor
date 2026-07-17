import Foundation

public struct SessionNameRefreshCandidate: Equatable, Sendable {
    public let sessionId: String
    public let currentName: String?

    public init(sessionId: String, currentName: String?) {
        self.sessionId = sessionId
        self.currentName = currentName
    }
}

public struct SessionNameRefreshChange: Equatable, Sendable {
    public let sessionId: String
    public let name: String

    public init(sessionId: String, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

public enum SessionNameRefreshPlanner {
    public static func changes(
        candidates: [SessionNameRefreshCandidate],
        resolvedNames: [String: String]
    ) -> [SessionNameRefreshChange] {
        candidates.compactMap { candidate in
            guard let raw = resolvedNames[candidate.sessionId] else {
                return nil
            }
            let resolved = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty,
                  resolved != candidate.currentName else {
                return nil
            }
            return SessionNameRefreshChange(sessionId: candidate.sessionId, name: resolved)
        }
    }
}

public enum SessionTranscriptTitlePolicy {
    public static func preferredName(
        sessionId: String,
        currentName: String?,
        transcriptTitle: String?
    ) -> String? {
        let current = currentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = current == sessionId || current == String(sessionId.prefix(8))
        if let current, !current.isEmpty, !isPlaceholder {
            return current
        }

        let transcript = transcriptTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transcript, !transcript.isEmpty {
            return transcript
        }
        return current?.isEmpty == false ? current : nil
    }
}
