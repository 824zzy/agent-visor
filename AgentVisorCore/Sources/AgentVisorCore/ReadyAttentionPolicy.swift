import Foundation

public enum ReadyAttentionPolicy {
    public static let defaultPulseWindow: TimeInterval = 7 * 60
    public static let defaultPulsePeriod: TimeInterval = 1.5
    public static let defaultPulseMinimumOpacity = 0.35
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

    public static func pulseOpacity(
        isReady: Bool,
        phaseChangedAt: Date,
        acknowledgedAt: Date?,
        now: Date,
        pulseWindow: TimeInterval = defaultPulseWindow,
        pulsePeriod: TimeInterval = defaultPulsePeriod,
        minimumOpacity: Double = defaultPulseMinimumOpacity
    ) -> Double {
        guard shouldPulse(
            isReady: isReady,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedAt,
            now: now,
            pulseWindow: pulseWindow
        ) else { return 1 }
        let period = max(.leastNonzeroMagnitude, pulsePeriod)
        let phase = now.timeIntervalSince(phaseChangedAt)
            .truncatingRemainder(dividingBy: period) / period
        let wave = 0.5 + 0.5 * cos(phase * 2 * .pi)
        let floor = min(1, max(0, minimumOpacity))
        return floor + (1 - floor) * wave
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
