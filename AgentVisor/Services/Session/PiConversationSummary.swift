import AgentVisorCore
import Foundation

/// Bounded bootstrap metadata path kept separate from Pi's full-history actor.
/// Historical 100+ MB transcripts therefore cannot queue whole-file parsing
/// ahead of a user opening Chat or a live session refresh.
actor PiConversationSummary {
    static let shared = PiConversationSummary()

    private struct FileSignature: Equatable {
        let byteCount: UInt64
        let modificationDate: Date
    }

    private struct CachedSummary {
        let signature: FileSignature
        let info: ConversationInfo
    }

    private var cache: [String: CachedSummary] = [:]

    func loadConversationInfo(
        sessionId: String,
        transcriptPath: String
    ) -> ConversationInfo {
        guard let signature = Self.signature(path: transcriptPath) else {
            return cache[transcriptPath]?.info ?? PiConversationParser.emptyInfo()
        }
        if let cached = cache[transcriptPath], cached.signature == signature {
            return cached.info
        }
        guard let summary = PiTranscriptSummaryReader.read(path: transcriptPath) else {
            return cache[transcriptPath]?.info ?? PiConversationParser.emptyInfo()
        }

        let info = PiConversationParser.projectHistory(
            from: summary.transcript
        ).conversationInfo
        cache[transcriptPath] = CachedSummary(signature: signature, info: info)
        return info
    }

    private static func signature(path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(
            byteCount: size.uint64Value,
            modificationDate: modificationDate
        )
    }
}
