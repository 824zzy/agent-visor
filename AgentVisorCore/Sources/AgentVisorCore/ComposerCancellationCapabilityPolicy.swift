import Foundation

/// Provider-neutral composer cancellation availability.
///
/// Context compaction is deliberately not interruptible from the composer:
/// Escape must not be sent to a terminal while the provider is rewriting its
/// context, and must not clear the user's draft as a side effect.
public struct ComposerCancellationAvailability: Equatable, Sendable {
    public let canCancel: Bool
    public let reason: String?
    public let accessibilityLabel: String

    public init(canCancel: Bool, reason: String? = nil, accessibilityLabel: String) {
        self.canCancel = canCancel
        self.reason = reason
        self.accessibilityLabel = accessibilityLabel
    }
}

/// The chat-level Escape decision is deliberately separate from capability
/// presentation. This lets the window consume compaction Escape without
/// relying on a SwiftUI view implementation detail (and makes the no-op
/// behavior executable in Core tests).
public enum ComposerEscapeAction: Equatable, Sendable {
    case cancel
    case consumeCompaction
    case clearDraft
}

public enum ComposerCancellationCapabilityPolicy {
    public static func escapeAction(phase: SessionPhase) -> ComposerEscapeAction {
        switch phase {
        case .processing:
            return .cancel
        case .compacting:
            return .consumeCompaction
        case .idle, .waitingForInput, .waitingForApproval, .ended:
            return .clearDraft
        }
    }

    public static func availability(
        phase: SessionPhase
    ) -> ComposerCancellationAvailability {
        switch phase {
        case .processing:
            return ComposerCancellationAvailability(
                canCancel: true,
                accessibilityLabel: "Stop the working turn"
            )
        case .compacting:
            return ComposerCancellationAvailability(
                canCancel: false,
                reason: "Context compaction cannot be stopped from the composer.",
                accessibilityLabel: "Stopping unavailable while context is compacting"
            )
        case .idle, .waitingForInput, .waitingForApproval, .ended:
            return ComposerCancellationAvailability(
                canCancel: false,
                accessibilityLabel: "Stopping unavailable for this session"
            )
        }
    }

    /// Processing alone is not enough to advertise Stop. Direct terminal
    /// cancellation is available only for a known host route with a live,
    /// identity-verified provider target. The legacy phase-only overload is
    /// retained for presentation contexts that do not own runtime evidence.
    public static func availability(
        phase: SessionPhase,
        terminalHost: TerminalHost?,
        hasVerifiedTarget: Bool
    ) -> ComposerCancellationAvailability {
        let phaseAvailability = availability(phase: phase)
        guard phase == .processing else { return phaseAvailability }
        let routeAvailable: Bool
        switch terminalHost {
        case .ghostty, .iterm2, .terminalApp:
            routeAvailable = true
        case .claudeDesktop, .codexApp, .vscode, .cursor, .zed, .unknown, .none:
            routeAvailable = false
        }
        guard routeAvailable, hasVerifiedTarget else {
            return ComposerCancellationAvailability(
                canCancel: false,
                reason: "Stopping is unavailable because this terminal target is not verified.",
                accessibilityLabel: "Stopping unavailable until the terminal target is verified"
            )
        }
        return phaseAvailability
    }
}
