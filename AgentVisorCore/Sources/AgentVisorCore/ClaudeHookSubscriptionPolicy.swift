import Foundation

public enum ClaudeHookMatcher: Equatable, Sendable {
    case none
    case wildcard
    case compaction
}

public struct ClaudeHookSubscription: Equatable, Sendable {
    public let event: String
    public let matcher: ClaudeHookMatcher
    public let timeoutSeconds: Int?

    public init(event: String, matcher: ClaudeHookMatcher, timeoutSeconds: Int? = nil) {
        self.event = event
        self.matcher = matcher
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ClaudeHookSubscriptionPolicy {
    public static let subscriptions: [ClaudeHookSubscription] = [
        .init(event: "UserPromptSubmit", matcher: .none),
        .init(event: "PreToolUse", matcher: .wildcard),
        .init(event: "PostToolUse", matcher: .wildcard),
        .init(event: "PostToolUseFailure", matcher: .wildcard),
        .init(event: "PermissionRequest", matcher: .wildcard, timeoutSeconds: 86_400),
        .init(event: "Notification", matcher: .wildcard),
        .init(event: "Stop", matcher: .none),
        .init(event: "StopFailure", matcher: .none),
        .init(event: "SubagentStop", matcher: .none),
        .init(event: "SessionStart", matcher: .none),
        .init(event: "SessionEnd", matcher: .none),
        .init(event: "PreCompact", matcher: .compaction),
        .init(event: "PostCompact", matcher: .compaction),
    ]
}
