import Foundation

/// Compact relative-timestamp formatter for the sidebar's right-edge
/// chip ("23h", "1w", "5m"). Mirrors Codex's session-bar display.
///
/// Buckets, ascending: seconds → minutes → hours → days → weeks →
/// months → years. The smallest user-perceivable bucket is minutes —
/// "now" is intentionally NOT a value because the live status dot
/// already signals "active right now," and a constantly-flickering
/// "now" → "1m" → "2m" caption next to it would be visual noise.
public enum RelativeTimestampFormatter {
    /// Returns the compact label, or `nil` when the elapsed interval
    /// is below the minute floor (so the caller can omit the chip
    /// entirely rather than rendering an empty Text).
    public static func format(
        elapsed: TimeInterval,
        now: Date = Date()
    ) -> String? {
        // Negative intervals (timestamp in the future from a clock
        // skew or a freshly-replayed JSONL with a forward-dated
        // line) clamp to nil — same as "below floor."
        guard elapsed >= 60 else { return nil }

        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        // Months: 30-day approximation. Doesn't matter that it's not
        // calendar-accurate — a sidebar chip showing "2mo" vs "3mo"
        // for a week-of-error is not user-meaningful.
        let months = days / 30
        if months < 12 { return "\(months)mo" }

        let years = days / 365
        return "\(years)y"
    }

    /// Convenience for the common call site: caller has a `Date`,
    /// not an elapsed interval.
    public static func format(since date: Date, now: Date = Date()) -> String? {
        format(elapsed: now.timeIntervalSince(date), now: now)
    }
}
