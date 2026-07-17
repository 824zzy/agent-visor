import Foundation

public enum ClaudeTranscriptRecordIdentity {
    public static func resolve(
        recordUUID: String?,
        providerMessageID: String?
    ) -> String? {
        _ = providerMessageID
        guard let recordUUID else { return nil }
        let normalized = recordUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
