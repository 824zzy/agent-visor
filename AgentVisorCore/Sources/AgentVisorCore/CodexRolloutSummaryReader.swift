import Foundation

public struct CodexRolloutSummary: Equatable, Sendable {
    public let transcript: CodexParsedTranscript
    public let turnContextScan: CodexTurnContextScanState?

    public init(
        transcript: CodexParsedTranscript,
        turnContextScan: CodexTurnContextScanState?
    ) {
        self.transcript = transcript
        self.turnContextScan = turnContextScan
    }
}

public enum CodexRolloutSummaryReader {
    public static func read(
        path: String,
        previousTurnContextScan: CodexTurnContextScanState? = nil
    ) -> CodexRolloutSummary? {
        guard let data = JSONLHeadTailFileReader.read(path: path) else {
            return nil
        }

        var transcript = CodexTranscriptParser.parse(data: data)
        let turnContextScan = CodexTurnContextFileScanner.scan(
            path: path,
            previous: previousTurnContextScan
        )
        if let latestRecord = turnContextScan?.latestRecord {
            let latest = CodexTranscriptParser.parse(data: latestRecord)
            transcript.modelName = latest.modelName ?? transcript.modelName
            transcript.effortLevel = latest.effortLevel ?? transcript.effortLevel
            transcript.approvalPolicy = latest.approvalPolicy ?? transcript.approvalPolicy
            transcript.sandboxPolicyType = latest.sandboxPolicyType ?? transcript.sandboxPolicyType
        }

        return CodexRolloutSummary(
            transcript: transcript,
            turnContextScan: turnContextScan
        )
    }
}
