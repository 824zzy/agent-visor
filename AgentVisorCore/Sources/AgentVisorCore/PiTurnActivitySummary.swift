import Foundation

public struct PiTurnActivitySummary: Equatable, Sendable {
    public let actionCount: Int
    public let countLabel: String
    public let activityLabel: String

    public init(actionCount: Int, countLabel: String, activityLabel: String) {
        self.actionCount = actionCount
        self.countLabel = countLabel
        self.activityLabel = activityLabel
    }
}

/// Pi-specific projection of raw tool names into a compact turn header.
/// Reasoning and progress prose never enter this interface, so they cannot
/// inflate the action count.
public enum PiTurnActivitySummarizer {
    public static func summarize(rawToolNames: [String]) -> PiTurnActivitySummary {
        let tools = rawToolNames.map {
            ToolNameMapper.canonical(for: $0, agent: .pi)
        }
        let activity = ClaudeTurnActivitySummarizer.summarize(tools)
        let count = tools.count
        let countLabel: String
        switch count {
        case 0: countLabel = ""
        case 1: countLabel = "1 action"
        default: countLabel = "\(count) actions"
        }
        return PiTurnActivitySummary(
            actionCount: count,
            countLabel: countLabel,
            activityLabel: count == 0 ? "" : activity.label(maxClauses: 2)
        )
    }
}
