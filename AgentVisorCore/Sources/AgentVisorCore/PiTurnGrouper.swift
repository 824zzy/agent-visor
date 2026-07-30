import Foundation

/// Prompt-bounded turn grouping for Pi transcripts.
///
/// Pi persists reasoning, progress prose, tool calls, and final prose as one
/// chronological stream. This policy projects that stream into conversation
/// structure without discarding canonical transcript items:
///
///     prompt → grouped work → final answer
///
/// Reasoning ids are kept separate from ordinary detail ids so the app can
/// place them behind one nested `Reasoning (N)` disclosure. `actionCount`
/// counts tool invocations only.
public enum PiTurnGrouper {
    public enum ItemCategory: Equatable, Sendable {
        case prompt
        case assistantText
        case reasoning
        case action(hasError: Bool)
        case supportingWork(hasError: Bool)
        case sessionLevel
        case interactive
    }

    public struct ItemDescriptor: Equatable, Sendable {
        public let id: String
        public let category: ItemCategory

        public init(id: String, category: ItemCategory) {
            self.id = id
            self.category = category
        }
    }

    public static let headerSuffix = "-pihdr"

    public struct GroupedRow: Equatable, Sendable {
        public let parentId: String
        public let detailIds: [String]
        public let reasoningIds: [String]
        public let actionCount: Int
        public let hasError: Bool
        public let isLive: Bool

        public init(
            parentId: String,
            detailIds: [String],
            reasoningIds: [String],
            actionCount: Int,
            hasError: Bool,
            isLive: Bool
        ) {
            self.parentId = parentId
            self.detailIds = detailIds
            self.reasoningIds = reasoningIds
            self.actionCount = actionCount
            self.hasError = hasError
            self.isLive = isLive
        }

        static func standalone(_ id: String) -> GroupedRow {
            GroupedRow(
                parentId: id,
                detailIds: [],
                reasoningIds: [],
                actionCount: 0,
                hasError: false,
                isLive: false
            )
        }
    }

    public static func group(
        _ items: [ItemDescriptor],
        sessionIsProcessing: Bool
    ) -> [GroupedRow] {
        guard !items.isEmpty else { return [] }

        var turns: [[ItemDescriptor]] = []
        var current: [ItemDescriptor] = []
        for item in items {
            if case .prompt = item.category {
                if !current.isEmpty { turns.append(current) }
                current = [item]
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { turns.append(current) }

        var output: [GroupedRow] = []
        for (index, turn) in turns.enumerated() {
            let isLive = sessionIsProcessing && index == turns.count - 1
            output.append(contentsOf: fold(turn, isLive: isLive))
        }
        return output
    }

    private static func fold(_ turn: [ItemDescriptor], isLive: Bool) -> [GroupedRow] {
        let workIndices = turn.indices.filter { index in
            switch turn[index].category {
            case .reasoning, .action, .supportingWork:
                return true
            case .assistantText:
                return isLive
            case .prompt, .sessionLevel, .interactive:
                return false
            }
        }
        guard let firstWork = workIndices.first,
              let lastWork = workIndices.last else {
            return turn.map { .standalone($0.id) }
        }

        let headerId = turn[firstWork].id + headerSuffix
        var rows: [GroupedRow] = []
        var detailIds: [String] = []
        var reasoningIds: [String] = []
        var actionCount = 0
        var hasError = false
        var insertedHeader = false

        func reserveHeader() {
            guard !insertedHeader else { return }
            rows.append(GroupedRow(
                parentId: headerId,
                detailIds: [],
                reasoningIds: [],
                actionCount: 0,
                hasError: false,
                isLive: isLive
            ))
            insertedHeader = true
        }

        for (index, item) in turn.enumerated() {
            switch item.category {
            case .prompt, .sessionLevel, .interactive:
                rows.append(.standalone(item.id))

            case .reasoning:
                reserveHeader()
                reasoningIds.append(item.id)

            case .action(let itemHasError):
                reserveHeader()
                detailIds.append(item.id)
                actionCount += 1
                hasError = hasError || itemHasError

            case .supportingWork(let itemHasError):
                reserveHeader()
                detailIds.append(item.id)
                hasError = hasError || itemHasError

            case .assistantText:
                if isLive || index <= lastWork {
                    reserveHeader()
                    detailIds.append(item.id)
                } else {
                    rows.append(.standalone(item.id))
                }
            }
        }

        if let slot = rows.firstIndex(where: { $0.parentId == headerId }) {
            rows[slot] = GroupedRow(
                parentId: headerId,
                detailIds: detailIds,
                reasoningIds: reasoningIds,
                actionCount: actionCount,
                hasError: hasError,
                isLive: isLive
            )
        }
        return rows
    }
}
