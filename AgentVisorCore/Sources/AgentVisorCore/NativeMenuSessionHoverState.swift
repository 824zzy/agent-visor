import Foundation

public struct NativeMenuSessionDetailPresentation: Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let phase: NativeHelperPillPhase
    public let rows: [SessionHoverDetailRow]
    public let context: SessionHoverContextPresentation?
    public let shortcutLabel: String?

    public init(
        id: String,
        title: String,
        status: String,
        phase: NativeHelperPillPhase,
        rows: [SessionHoverDetailRow],
        context: SessionHoverContextPresentation? = nil,
        shortcutLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.phase = phase
        self.rows = rows
        self.context = context
        self.shortcutLabel = shortcutLabel
    }
}

public struct NativeMenuSessionHoverState: Sendable {
    public static let delay: TimeInterval = 0.35

    private var hoveredID: String?
    private var enteredAt: TimeInterval?

    public init() {}

    public mutating func pointerEntered(_ id: String, at: TimeInterval) {
        hoveredID = id
        enteredAt = at
    }

    public mutating func pointerExited(_ id: String) {
        guard hoveredID == id else { return }
        hoveredID = nil
        enteredAt = nil
    }

    public mutating func retain(sessionIDs: Set<String>) {
        guard let hoveredID, sessionIDs.contains(hoveredID) else {
            self.hoveredID = nil
            enteredAt = nil
            return
        }
    }

    public func presentation(
        pills: [String: NativeHelperPill],
        at: TimeInterval,
        date: Date = Date(),
        shortcutLabel: String? = nil
    ) -> NativeMenuSessionDetailPresentation? {
        guard let hoveredID,
              let enteredAt,
              at >= enteredAt + Self.delay,
              let pill = pills[hoveredID] else { return nil }
        if let inspector = pill.inspector {
            let rows = [
                SessionHoverDetailRow(
                    label: "Latest turn",
                    value: inspector.runtimeItems.joined(separator: " · ")
                ),
            ] + inspector.detailRows.map {
                SessionHoverDetailRow(label: $0.label, value: $0.value)
            } + [
                SessionHoverDetailRow(label: "Project", value: inspector.projectPath),
                SessionHoverDetailRow(
                    label: "Activity",
                    value: activityLabel(from: inspector.activityAt, at: date)
                ),
            ]
            return NativeMenuSessionDetailPresentation(
                id: pill.id,
                title: pill.title,
                status: inspector.status,
                phase: pill.phase,
                rows: rows,
                context: inspector.context.map {
                    SessionHoverContextPresentation(
                        usedLabel: $0.usedLabel,
                        windowLabel: $0.windowLabel,
                        percentage: $0.percentage
                    )
                },
                shortcutLabel: shortcutLabel
            )
        }
        return NativeMenuSessionDetailPresentation(
            id: pill.id,
            title: pill.title,
            status: pill.subtitle ?? status(for: pill.phase),
            phase: pill.phase,
            rows: [
                pill.source.map { SessionHoverDetailRow(label: "Source", value: $0) },
                pill.project.map { SessionHoverDetailRow(label: "Project", value: $0) },
                pill.owner.map { SessionHoverDetailRow(label: "Opens in", value: $0) },
            ].compactMap { $0 },
            shortcutLabel: shortcutLabel
        )
    }

    private func activityLabel(from value: String, at date: Date) -> String {
        guard let activity = try? Date(value, strategy: .iso8601) else { return value }
        let seconds = max(0, Int(date.timeIntervalSince(activity)))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    private func status(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: return "Needs you"
        case .ready: return "Ready to continue"
        case .working: return "In progress"
        case .history: return "History"
        }
    }
}
