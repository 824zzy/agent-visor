import Foundation

/// Pure description of one approval notification — used by Phase 4
/// of the window-mode rollout to drive UNNotification content. The
/// AppKit/UNUserNotificationCenter wiring in the host turns this
/// struct into a UNNotificationRequest. Extracted to Core so the
/// composition logic (title, identifier round-trip) is unit-testable.
public struct ApprovalNotificationContent: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let body: String

    public init(title: String, subtitle: String, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    public static func make(displayTitle: String, toolName: String, input: String) -> ApprovalNotificationContent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.isEmpty {
            body = ""
        } else if trimmed.count > 240 {
            body = String(trimmed.prefix(240))
        } else {
            body = trimmed
        }
        return ApprovalNotificationContent(
            title: "\(toolName) needs approval",
            subtitle: displayTitle,
            body: body
        )
    }

    // MARK: - Identifier round-trip

    private static let identifierPrefix = "cv.approval."
    private static let separator = "|"

    /// Stable identifier: `cv.approval.<sessionId>|<toolUseId>`.
    /// Encoded so the notification action handler can recover both
    /// pieces and dispatch to ClaudeSessionMonitor.approve/deny.
    public static func identifier(sessionId: String, toolUseId: String) -> String {
        identifierPrefix + sessionId + separator + toolUseId
    }

    public static func parseIdentifier(_ id: String) -> (sessionId: String, toolUseId: String)? {
        guard id.hasPrefix(identifierPrefix) else { return nil }
        let payload = String(id.dropFirst(identifierPrefix.count))
        let parts = payload.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let sid = String(parts[0])
        let tid = String(parts[1])
        guard !sid.isEmpty, !tid.isEmpty else { return nil }
        return (sid, tid)
    }
}
