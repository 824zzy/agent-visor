import Foundation

public enum SessionInspectorPhase: Equatable, Sendable {
    case needsAttention
    case ready
    case working
    case compacting
    case recent
    case ended
}

public enum SessionInspectorAction: Equatable, Sendable {
    case openOriginal
    case inspectTranscript
}

public struct SessionInspectorActionPresentation: Equatable, Sendable {
    public let action: SessionInspectorAction
    public let title: String

    public init(action: SessionInspectorAction, title: String) {
        self.action = action
        self.title = title
    }
}

public struct SessionInspectorPresentation: Equatable, Sendable {
    public let statusTitle: String
    public let statusDetail: String
    public let primaryAction: SessionInspectorActionPresentation?
    public let secondaryAction: SessionInspectorActionPresentation?

    public init(
        statusTitle: String,
        statusDetail: String,
        primaryAction: SessionInspectorActionPresentation?,
        secondaryAction: SessionInspectorActionPresentation?
    ) {
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }
}

public enum SessionInspectorPolicy {
    public static func presentation(
        phase: SessionInspectorPhase,
        ownerDisplayName: String?,
        canOpenOriginal: Bool,
        canInspectTranscript: Bool,
        canHandleAttention: Bool
    ) -> SessionInspectorPresentation {
        let openOriginal = canOpenOriginal
            ? SessionInspectorActionPresentation(
                action: .openOriginal,
                title: phase == .needsAttention && !canHandleAttention
                    ? "Review in \(ownerDisplayName ?? "original app")"
                    : "Open in \(ownerDisplayName ?? "original app")"
            )
            : nil
        let inspectTranscript = canInspectTranscript
            ? SessionInspectorActionPresentation(
                action: .inspectTranscript,
                title: "Inspect transcript"
            )
            : nil

        if phase == .needsAttention, canHandleAttention, canInspectTranscript {
            return SessionInspectorPresentation(
                statusTitle: "Needs attention",
                statusDetail: "A decision or answer is blocking this session.",
                primaryAction: SessionInspectorActionPresentation(
                    action: .inspectTranscript,
                    title: "Review request"
                ),
                secondaryAction: openOriginal
            )
        }

        if phase == .needsAttention {
            return SessionInspectorPresentation(
                statusTitle: "Needs attention",
                statusDetail: "A decision or answer is blocking this session.",
                primaryAction: openOriginal ?? inspectTranscript,
                secondaryAction: openOriginal == nil ? nil : inspectTranscript
            )
        }

        if phase == .ended {
            return SessionInspectorPresentation(
                statusTitle: "Session ended",
                statusDetail: "The transcript remains available for inspection.",
                primaryAction: inspectTranscript,
                secondaryAction: nil
            )
        }

        let status: (title: String, detail: String)
        switch phase {
        case .ready:
            status = ("Ready for you", "The latest turn is complete.")
        case .working:
            status = ("Working", "The agent is processing the current turn.")
        case .compacting:
            status = ("Compacting context", "The agent is preparing more room for the conversation.")
        case .recent:
            status = ("Recent session", "No turn is currently active.")
        case .needsAttention, .ended:
            status = ("Session", "Session details are available.")
        }

        return SessionInspectorPresentation(
            statusTitle: status.title,
            statusDetail: status.detail,
            primaryAction: openOriginal ?? inspectTranscript,
            secondaryAction: openOriginal == nil ? nil : inspectTranscript
        )
    }
}
