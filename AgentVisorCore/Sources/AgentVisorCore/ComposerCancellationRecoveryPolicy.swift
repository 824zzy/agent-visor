import Foundation

/// The immutable identity of the composer submission that is currently being
/// cancelled. The app keeps the full `ImageAttachment` values alongside this
/// provider-neutral snapshot; Core only needs stable attachment identities to
/// decide whether a later edit may be overwritten.
public struct ComposerCancellationSnapshot: Equatable, Sendable {
    public let sessionId: String
    public let text: String
    public let attachmentIDs: [String]
    public let pendingEchoID: String?
    public let submittedRevision: Int
    public let clearedRevision: Int

    public init(
        sessionId: String,
        text: String,
        attachmentIDs: [String],
        pendingEchoID: String?,
        submittedRevision: Int,
        clearedRevision: Int
    ) {
        self.sessionId = sessionId
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.pendingEchoID = pendingEchoID
        self.submittedRevision = submittedRevision
        self.clearedRevision = clearedRevision
    }
}

public enum ComposerCancellationRecoveryDecision: Equatable, Sendable {
    case restore
    case preserveNewerComposer
}

public enum ComposerCancellationRecoveryPolicy {
    /// Restore only the exact post-submit empty composer. A revision guard is
    /// required even when a user later clears their newer draft back to empty;
    /// otherwise a confirmed cancel could overwrite that newer edit's intent.
    public static func decision(
        snapshot: ComposerCancellationSnapshot,
        currentSessionId: String,
        currentText: String,
        currentAttachmentIDs: [String],
        currentRevision: Int
    ) -> ComposerCancellationRecoveryDecision {
        guard snapshot.sessionId == currentSessionId,
              currentRevision == snapshot.clearedRevision,
              currentText.isEmpty,
              currentAttachmentIDs.isEmpty else {
            return .preserveNewerComposer
        }
        return .restore
    }
}
