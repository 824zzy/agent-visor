import Foundation

public struct MenuBarUsageSlotLayout: Equatable, Sendable {
    public let showsCodex: Bool
    public let showsClaude: Bool
    public let usageSlotWidth: Double
    public let sessionUsableWidth: Double
}

public enum MenuBarUsageSlotPolicy {
    public static func layout(
        usableWidth: Double,
        spacing: Double,
        codexWidth: Double?,
        claudeWidth: Double?
    ) -> MenuBarUsageSlotLayout {
        let gap = max(0, spacing)
        var remaining = max(0, usableWidth)
        var renderedWidths: [Double] = []
        var showsCodex = false
        var showsClaude = false

        if let width = normalized(codexWidth), width <= remaining {
            showsCodex = true
            renderedWidths.append(width)
            remaining = max(0, remaining - width - gap)
        }
        if let width = normalized(claudeWidth), width <= remaining {
            showsClaude = true
            renderedWidths.append(width)
            remaining = max(0, remaining - width - gap)
        }

        return MenuBarUsageSlotLayout(
            showsCodex: showsCodex,
            showsClaude: showsClaude,
            usageSlotWidth: renderedWidths.reduce(0, +)
                + (renderedWidths.count > 1 ? gap : 0),
            sessionUsableWidth: remaining
        )
    }

    private static func normalized(_ width: Double?) -> Double? {
        guard let width, width > 0 else { return nil }
        return width
    }
}
