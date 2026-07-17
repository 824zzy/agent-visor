import Foundation

public struct CodexUsageWindow: Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public var remainingPercent: Int {
        100 - usedPercent
    }

    public init(
        usedPercent: Int,
        windowDurationMinutes: Int?,
        resetsAt: Date?
    ) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let primary: CodexUsageWindow?
    public let secondary: CodexUsageWindow?
    public let resetCreditsAvailable: Int?
    public let observedAt: Date

    public init(
        primary: CodexUsageWindow?,
        secondary: CodexUsageWindow?,
        resetCreditsAvailable: Int?,
        observedAt: Date
    ) {
        self.primary = primary
        self.secondary = secondary
        self.resetCreditsAvailable = resetCreditsAvailable
        self.observedAt = observedAt
    }

    public func merging(_ update: CodexUsageSnapshot) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            primary: update.primary ?? primary,
            secondary: update.secondary ?? secondary,
            resetCreditsAvailable: update.resetCreditsAvailable ?? resetCreditsAvailable,
            observedAt: update.observedAt
        )
    }
}

public enum CodexUsageWindowSource: Equatable, Sendable {
    case primary
    case secondary
}

public enum CodexUsageGlanceTone: Equatable, Sendable {
    case normal
    case warning
    case critical
}

public struct CodexUsageWindowPresentation: Equatable, Sendable {
    public let label: String
    public let remainingPercent: Int?
    public let source: CodexUsageWindowSource?
    public let tone: CodexUsageGlanceTone?

    public var text: String {
        "\(label) \(remainingPercent.map(String.init) ?? "--")%"
    }
}

public struct CodexUsageGlancePresentation: Equatable, Sendable {
    public let fiveHour: CodexUsageWindowPresentation
    public let sevenDay: CodexUsageWindowPresentation

    public var label: String {
        "\(fiveHour.text) | \(sevenDay.text)"
    }
}

public struct CodexUsagePillReservation: Equatable, Sendable {
    public let showsUsage: Bool
    public let sessionUsableWidth: Double
}

public enum CodexUsageAvailability: Equatable, Sendable {
    case disabled
    case checking
    case available
    case stale
    case unavailable

    public var showsPill: Bool {
        self == .available || self == .stale
    }
}

public enum CodexUsageGlancePolicy {
    public static let fixedWidth = 114.0

    public static func availability(
        preferenceEnabled: Bool,
        snapshot: CodexUsageSnapshot?,
        isRefreshing: Bool,
        hasAttemptedRefresh: Bool,
        hasRefreshError: Bool
    ) -> CodexUsageAvailability {
        guard preferenceEnabled else { return .disabled }
        if let snapshot, hasMeaningfulWindow(snapshot) {
            return hasRefreshError ? .stale : .available
        }
        if isRefreshing || !hasAttemptedRefresh {
            return .checking
        }
        return .unavailable
    }

    private static func hasMeaningfulWindow(_ snapshot: CodexUsageSnapshot) -> Bool {
        guard let presentation = presentation(for: snapshot) else { return false }
        return presentation.fiveHour.remainingPercent != nil
            || presentation.sevenDay.remainingPercent != nil
    }

    public static func presentation(
        for snapshot: CodexUsageSnapshot?
    ) -> CodexUsageGlancePresentation {
        snapshot.flatMap { presentation(for: $0) } ?? CodexUsageGlancePresentation(
            fiveHour: placeholder(label: "5h"),
            sevenDay: placeholder(label: "7d")
        )
    }

    public static func presentation(
        for snapshot: CodexUsageSnapshot
    ) -> CodexUsageGlancePresentation? {
        guard snapshot.primary != nil || snapshot.secondary != nil else { return nil }
        let fiveHour = windowPresentation(
            label: "5h",
            durationMinutes: 300,
            fallback: (.primary, snapshot.primary),
            snapshot: snapshot
        )
        let sevenDay = windowPresentation(
            label: "7d",
            durationMinutes: 10_080,
            fallback: (.secondary, snapshot.secondary),
            snapshot: snapshot
        )
        return CodexUsageGlancePresentation(
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private static func windowPresentation(
        label: String,
        durationMinutes: Int,
        fallback: (CodexUsageWindowSource, CodexUsageWindow?),
        snapshot: CodexUsageSnapshot
    ) -> CodexUsageWindowPresentation {
        let candidates: [(CodexUsageWindowSource, CodexUsageWindow?)] = [
            (.primary, snapshot.primary),
            (.secondary, snapshot.secondary),
        ]
        let match = candidates.first {
            $0.1?.windowDurationMinutes == durationMinutes
        } ?? (fallback.1?.windowDurationMinutes == nil ? fallback : (fallback.0, nil))
        let remaining = match.1?.remainingPercent
        return CodexUsageWindowPresentation(
            label: label,
            remainingPercent: remaining,
            source: match.1 == nil ? nil : match.0,
            tone: remaining.map(tone)
        )
    }

    private static func placeholder(label: String) -> CodexUsageWindowPresentation {
        CodexUsageWindowPresentation(
            label: label,
            remainingPercent: nil,
            source: nil,
            tone: nil
        )
    }

    public static func tone(remainingPercent: Int) -> CodexUsageGlanceTone {
        if remainingPercent <= 10 { return .critical }
        if remainingPercent <= 25 { return .warning }
        return .normal
    }

    public static func durationLabel(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)d"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    public static func reserveRightSide(
        usableWidth: Double,
        spacing: Double,
        enabled: Bool
    ) -> CodexUsagePillReservation {
        let width = max(0, usableWidth)
        guard enabled, width >= fixedWidth else {
            return CodexUsagePillReservation(
                showsUsage: false,
                sessionUsableWidth: width
            )
        }
        return CodexUsagePillReservation(
            showsUsage: true,
            sessionUsableWidth: max(0, width - fixedWidth - max(0, spacing))
        )
    }
}

public enum CodexUsageSnapshotParser {
    public static func response(
        _ payload: AnyCodableEquatableBox,
        observedAt: Date
    ) -> CodexUsageSnapshot? {
        guard let root = payload.dictionary,
              let rateLimits = root["rateLimits"] as? [String: Any] else {
            return nil
        }
        let credits = root["rateLimitResetCredits"] as? [String: Any]
        let snapshot = CodexUsageSnapshot(
            primary: window(rateLimits["primary"]),
            secondary: window(rateLimits["secondary"]),
            resetCreditsAvailable: integer(credits?["availableCount"]),
            observedAt: observedAt
        )
        guard snapshot.primary != nil || snapshot.secondary != nil else { return nil }
        return snapshot
    }

    public static func notification(
        _ payload: AnyCodableEquatableBox,
        observedAt: Date
    ) -> CodexUsageSnapshot? {
        guard let root = payload.dictionary,
              let rateLimits = root["rateLimits"] as? [String: Any] else {
            return nil
        }
        let snapshot = CodexUsageSnapshot(
            primary: window(rateLimits["primary"]),
            secondary: window(rateLimits["secondary"]),
            resetCreditsAvailable: nil,
            observedAt: observedAt
        )
        guard snapshot.primary != nil || snapshot.secondary != nil else { return nil }
        return snapshot
    }

    private static func window(_ raw: Any?) -> CodexUsageWindow? {
        guard let object = raw as? [String: Any],
              let usedPercent = integer(object["usedPercent"]) else {
            return nil
        }
        let resetsAt = integer(object["resetsAt"])
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return CodexUsageWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: integer(object["windowDurationMins"]),
            resetsAt: resetsAt
        )
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }
}
