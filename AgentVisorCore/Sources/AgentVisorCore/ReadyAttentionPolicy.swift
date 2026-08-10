import Foundation

public enum PillCompletionAttentionState: Equatable, Sendable {
    case none
    case unseen
    case seen
}

/// Durable attention for completed turns in the constrained menu-bar surface.
/// Elapsed time may stop motion, but only activation acknowledges a completion.
public enum PillCompletionAttentionPolicy {
    public static let defaultPulseWindow: TimeInterval = 7 * 60

    public static func state(
        completedAt: Date?,
        acknowledgedAt: Date?
    ) -> PillCompletionAttentionState {
        guard let completedAt else { return .none }
        guard let acknowledgedAt, acknowledgedAt >= completedAt else {
            return .unseen
        }
        return .seen
    }

    public static func acknowledgmentDateAfterActivation(
        completedAt: Date?,
        existingAcknowledgedAt: Date?,
        activatedAt: Date
    ) -> Date? {
        guard let completedAt, activatedAt >= completedAt else {
            return existingAcknowledgedAt
        }
        guard state(
            completedAt: completedAt,
            acknowledgedAt: existingAcknowledgedAt
        ) == .unseen else {
            return existingAcknowledgedAt
        }
        return activatedAt
    }

    public static func shouldPulse(
        completedAt: Date?,
        acknowledgedAt: Date?,
        now: Date,
        pulseWindow: TimeInterval = defaultPulseWindow
    ) -> Bool {
        guard state(completedAt: completedAt, acknowledgedAt: acknowledgedAt) == .unseen,
              let completedAt else {
            return false
        }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age < pulseWindow
    }
}

/// Resolves a stable completion identity from repeated session snapshots.
/// `nil` previous state represents app startup; a later durable evidence date
/// then detects work that completed while Agent Visor was not running.
public enum PillCompletionObservationPolicy {
    public static func completionDateAfterObservation(
        isReady: Bool,
        previousObservationWasReady: Bool?,
        observedCompletionAt: Date,
        existingCompletedAt: Date?
    ) -> Date? {
        guard isReady else { return existingCompletedAt }
        guard let existingCompletedAt else { return observedCompletionAt }

        if previousObservationWasReady == true {
            return existingCompletedAt
        }
        if previousObservationWasReady == false {
            return max(existingCompletedAt, observedCompletionAt)
        }
        return observedCompletionAt > existingCompletedAt
            ? observedCompletionAt
            : existingCompletedAt
    }
}

public enum ReadyAttentionPolicy {
    public static let defaultPulseWindow: TimeInterval = 7 * 60
    public static let defaultPositionHold: TimeInterval = 2

    public static func isAcknowledged(
        phaseChangedAt: Date,
        acknowledgedAt: Date?
    ) -> Bool {
        guard let acknowledgedAt else { return false }
        return acknowledgedAt >= phaseChangedAt
    }

    public static func acknowledgmentDateAfterNavigation(
        isReady: Bool,
        phaseChangedAt: Date,
        existingAcknowledgedAt: Date?,
        navigationAt: Date
    ) -> Date? {
        guard isReady, navigationAt >= phaseChangedAt else {
            return existingAcknowledgedAt
        }
        guard !isAcknowledged(
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: existingAcknowledgedAt
        ) else {
            return existingAcknowledgedAt
        }
        return navigationAt
    }

    public static func shouldPulse(
        isReady: Bool,
        phaseChangedAt: Date,
        acknowledgedAt: Date?,
        now: Date,
        pulseWindow: TimeInterval = defaultPulseWindow
    ) -> Bool {
        guard isReady else { return false }
        let age = now.timeIntervalSince(phaseChangedAt)
        guard age >= 0, age < pulseWindow else { return false }
        return !isAcknowledged(
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedAt
        )
    }

    public static func shouldRemainProminent(
        phaseChangedAt: Date,
        acknowledgedAt: Date?,
        now: Date,
        positionHold: TimeInterval = defaultPositionHold
    ) -> Bool {
        guard isAcknowledged(
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedAt
        ), let acknowledgedAt else {
            return true
        }
        return now < acknowledgedAt.addingTimeInterval(max(0, positionHold))
    }
}
