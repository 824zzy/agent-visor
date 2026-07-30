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
    public enum Authority: Equatable, Sendable {
        /// The transcript title fills an unnamed or placeholder session, but
        /// must not replace a stronger process- or index-resolved name.
        case fallback

        /// The transcript is the owning agent's canonical name store. Its
        /// latest non-empty active-branch title replaces an earlier value.
        case authoritative
    }

    public static func preferredName(
        sessionId: String,
        currentName: String?,
        transcriptTitle: String?,
        authority: Authority = .fallback
    ) -> String? {
        let current = currentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcriptTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        if authority == .authoritative,
           let transcript,
           !transcript.isEmpty {
            return transcript
        }

        let isPlaceholder = current == sessionId || current == String(sessionId.prefix(8))
        if let current, !current.isEmpty, !isPlaceholder {
            return current
        }

        if let transcript, !transcript.isEmpty {
            return transcript
        }
        return current?.isEmpty == false ? current : nil
    }
}
