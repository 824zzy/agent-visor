import Foundation

public struct PiTranscriptSummary: Equatable, Sendable {
    public let transcript: PiParsedTranscript
    public let sampledByteCount: Int

    public init(transcript: PiParsedTranscript, sampledByteCount: Int) {
        self.transcript = transcript
        self.sampledByteCount = sampledByteCount
    }
}

/// Bounded bootstrap reader for Sessions metadata. Large files contribute
/// only complete JSONL records from their head and tail; active-branch
/// reconstruction naturally stops when the omitted middle parent is absent.
public enum PiTranscriptSummaryReader {
    public static func read(path: String) -> PiTranscriptSummary? {
        guard let data = JSONLHeadTailFileReader.read(path: path) else {
            return nil
        }
        return PiTranscriptSummary(
            transcript: PiTranscriptParser.parse(data: data),
            sampledByteCount: data.count
        )
    }
}
