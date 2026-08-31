import Foundation

/// Parses the small, whitespace-oriented fields returned by `ps` probes.
/// Keeping this parser in Core makes malformed/missing process metadata a
/// testable fail-closed case instead of letting each AppKit caller invent a
/// different wildcard or trimming rule.
public enum TerminalProcessProbeParser {
    public static func pid(from output: String) -> Int? {
        guard let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else { return nil }
        return value
    }

    public static func tty(from output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "?", value != "??", value != "-" else {
            return nil
        }
        return TerminalProcessIdentity.normalizeTTY(value)
    }

    /// Parse the English POSIX `ps -o lstart=` representation. A fresh
    /// formatter is intentional: DateFormatter is not thread-safe, and
    /// identity probes may run concurrently during discovery.
    public static func startDate(from output: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(
            from: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
