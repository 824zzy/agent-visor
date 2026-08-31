import Foundation

public enum ImageAttachmentRetentionPolicy {
    public static let staleFileAge: TimeInterval = 24 * 60 * 60
    // ponytail: keep this reference cap coordinated with the recovery ledger
    // record/byte limits. A file is never released while an actionable or
    // awaiting-canonical delivery still names it.
    public static let maxRetainedAttachmentReferences = 512

    public enum TerminalEvent: Equatable, Sendable {
        case canonicalSuccess
        case explicitDismiss
        case expiredAfterRestore
    }

    /// A file may be released only after an exact terminal event and only if
    /// no live delivery still references its stable attachment ID.
    public static func mayRelease(
        attachmentID: String,
        event: TerminalEvent,
        retainedAttachmentIDs: Set<String>
    ) -> Bool {
        guard !attachmentID.isEmpty, !retainedAttachmentIDs.contains(attachmentID) else {
            return false
        }
        switch event {
        case .canonicalSuccess, .explicitDismiss, .expiredAfterRestore:
            return true
        }
    }

    /// Returns the exact subset of a terminal snapshot that may be released.
    /// Keeping this decision in Core lets app-owned scope stores perform the
    /// same check for canonical, dismissal, expiry, and generation cleanup;
    /// no mounted view needs to own attachment lifetime policy.
    public static func releasableAttachmentIDs(
        _ attachmentIDs: some Sequence<String>,
        event: TerminalEvent,
        retainedAttachmentIDs: Set<String>
    ) -> Set<String> {
        Set(attachmentIDs.filter { attachmentID in
            mayRelease(
                attachmentID: attachmentID,
                event: event,
                retainedAttachmentIDs: retainedAttachmentIDs
            )
        })
    }

    public static func cleanupDelay(
        for route: ImageSubmissionRoute
    ) -> TimeInterval? {
        switch route {
        case .terminalPathPrompt:
            return 24 * 60 * 60
        case .appServerLocalImage, .terminalAttachment:
            return 60
        case .unavailable:
            return nil
        }
    }
}
