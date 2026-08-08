import Foundation

/// Warning tone for a Claude usage value. Mirrors `CodexUsageGlanceTone`
/// but is derived from the authoritative server `severity` string when
/// present, falling back to used-percentage thresholds.
public enum ClaudeUsageSeverity: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// Map the server's `spend.severity` string. Unknown values are
    /// treated as `normal` so an unexpected label never fabricates alarm.
    public static func fromServer(_ raw: String?) -> ClaudeUsageSeverity? {
        switch raw?.lowercased() {
        case "normal", "ok", "none": return .normal
        case "warning", "warn", "approaching", "near_limit": return .warning
        case "critical", "exceeded", "over", "blocked", "reached": return .critical
        default: return nil
        }
    }
}

/// Enterprise / dollar-pool spend (`extra_usage` + `spend` blocks).
/// Amounts are integer minor units (cents for USD) with an `exponent`.
public struct ClaudeUsageSpend: Equatable, Sendable {
    public let usedMinor: Int
    public let limitMinor: Int
    public let exponent: Int
    public let currency: String
    public let usedPercent: Int
    public let severity: ClaudeUsageSeverity
    public let enabled: Bool

    public init(
        usedMinor: Int,
        limitMinor: Int,
        exponent: Int,
        currency: String,
        usedPercent: Int,
        severity: ClaudeUsageSeverity,
        enabled: Bool
    ) {
        self.usedMinor = max(0, usedMinor)
        self.limitMinor = max(0, limitMinor)
        self.exponent = exponent
        self.currency = currency
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.severity = severity
        self.enabled = enabled
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let spend: ClaudeUsageSpend?
    public let observedAt: Date

    public init(spend: ClaudeUsageSpend?, observedAt: Date) {
        self.spend = spend
        self.observedAt = observedAt
    }
}

public struct ClaudeUsageGlancePresentation: Equatable, Sendable {
    public let label: String
    public let percentText: String
    public let severity: ClaudeUsageSeverity?
}

public struct ClaudeUsagePillReservation: Equatable, Sendable {
    public let showsUsage: Bool
    public let sessionUsableWidth: Double
}

public enum ClaudeUsageAvailability: Equatable, Sendable {
    case disabled
    case checking
    case available
    case stale
    case unavailable

    public var showsPill: Bool { self == .available || self == .stale }
}

public enum ClaudeUsageGlancePolicy {
    /// Sized so the compact remaining-dollars label `CC $<remaining>` never
    /// clips at 10.5pt (worst-case `CC $1000` ≈ 52pt text + capsule breathing
    /// room). The full `used of limit` breakdown lives in the popover.
    public static let fixedWidth = 68.0

    public static func availability(
        preferenceEnabled: Bool,
        snapshot: ClaudeUsageSnapshot?,
        isRefreshing: Bool,
        hasAttemptedRefresh: Bool,
        hasRefreshError: Bool
    ) -> ClaudeUsageAvailability {
        guard preferenceEnabled else { return .disabled }
        if let snapshot, isMeaningful(snapshot) {
            return hasRefreshError ? .stale : .available
        }
        if isRefreshing || !hasAttemptedRefresh {
            return .checking
        }
        return .unavailable
    }

    private static func isMeaningful(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        guard let spend = snapshot.spend else { return false }
        return spend.enabled && spend.limitMinor > 0
    }

    public static func presentation(
        for snapshot: ClaudeUsageSnapshot?
    ) -> ClaudeUsageGlancePresentation {
        guard let spend = snapshot?.spend else {
            return ClaudeUsageGlancePresentation(
                label: "CC $--",
                percentText: "--%",
                severity: nil
            )
        }
        // Compact pill shows dollars REMAINING with a `CC` (Claude Code)
        // label; the used/limit breakdown and percentages live in the
        // popover. Tone still follows the remaining-based severity.
        let remainingMinor = max(0, spend.limitMinor - spend.usedMinor)
        return ClaudeUsageGlancePresentation(
            label: "CC \(dollars(minor: remainingMinor, exponent: spend.exponent))",
            percentText: "\(spend.usedPercent)%",
            severity: spend.severity
        )
    }

    /// Whole-dollar rendering for the compact pill: `$18`. A nonzero
    /// amount below one unit shows `<$1` so it never reads as free.
    public static func dollars(minor: Int, exponent: Int) -> String {
        let divisor = pow(10.0, Double(max(0, exponent)))
        let value = Double(minor) / divisor
        let symbol = "$"
        if value > 0, value < 1 { return "\(symbol)<1" }
        return "\(symbol)\(Int(value.rounded()))"
    }

    public static func reserveRightSide(
        usableWidth: Double,
        spacing: Double,
        enabled: Bool
    ) -> ClaudeUsagePillReservation {
        let width = max(0, usableWidth)
        guard enabled, width >= fixedWidth else {
            return ClaudeUsagePillReservation(showsUsage: false, sessionUsableWidth: width)
        }
        return ClaudeUsagePillReservation(
            showsUsage: true,
            sessionUsableWidth: max(0, width - fixedWidth - max(0, spacing))
        )
    }
}

public enum ClaudeUsageSnapshotParser {
    /// Parse the `/api/oauth/usage` response. Prefers the `spend` block;
    /// falls back to `extra_usage` when only that is present.
    public static func response(
        _ payload: AnyCodableEquatableBox,
        observedAt: Date
    ) -> ClaudeUsageSnapshot? {
        guard let root = payload.dictionary else { return nil }
        let spend = spendFromSpendBlock(root["spend"])
            ?? spendFromExtraUsage(root["extra_usage"])
        guard spend != nil else { return nil }
        return ClaudeUsageSnapshot(spend: spend, observedAt: observedAt)
    }

    private static func spendFromSpendBlock(_ raw: Any?) -> ClaudeUsageSpend? {
        guard let block = raw as? [String: Any],
              let used = block["used"] as? [String: Any],
              let limit = block["limit"] as? [String: Any],
              let usedMinor = integer(used["amount_minor"]),
              let limitMinor = integer(limit["amount_minor"]),
              limitMinor > 0 else {
            return nil
        }
        let exponent = integer(used["exponent"]) ?? 2
        let currency = (used["currency"] as? String) ?? "USD"
        let percent = integer(block["percent"])
            ?? Int((Double(usedMinor) / Double(limitMinor) * 100).rounded())
        let severity = ClaudeUsageSeverity.fromServer(block["severity"] as? String)
            ?? derivedSeverity(usedPercent: percent)
        let enabled = (block["enabled"] as? Bool) ?? true
        return ClaudeUsageSpend(
            usedMinor: usedMinor,
            limitMinor: limitMinor,
            exponent: exponent,
            currency: currency,
            usedPercent: percent,
            severity: severity,
            enabled: enabled
        )
    }

    private static func spendFromExtraUsage(_ raw: Any?) -> ClaudeUsageSpend? {
        guard let block = raw as? [String: Any],
              let limitMinor = integer(block["monthly_limit"]),
              limitMinor > 0 else {
            return nil
        }
        let usedMinor = integer(block["used_credits"]) ?? 0
        let exponent = integer(block["decimal_places"]) ?? 2
        let currency = (block["currency"] as? String) ?? "USD"
        let percent = Int((Double(usedMinor) / Double(limitMinor) * 100).rounded())
        let enabled = (block["is_enabled"] as? Bool) ?? true
        let reached = (block["spend_limit_reached"] as? Bool) ?? false
        let severity: ClaudeUsageSeverity = reached ? .critical : derivedSeverity(usedPercent: percent)
        return ClaudeUsageSpend(
            usedMinor: usedMinor,
            limitMinor: limitMinor,
            exponent: exponent,
            currency: currency,
            usedPercent: percent,
            severity: severity,
            enabled: enabled
        )
    }

    private static func derivedSeverity(usedPercent: Int) -> ClaudeUsageSeverity {
        if usedPercent >= 90 { return .critical }
        if usedPercent >= 75 { return .warning }
        return .normal
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? Double { return Int(value.rounded()) }
        return nil
    }
}
