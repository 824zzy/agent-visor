import Foundation

public enum PiToolBatchPlanner {
    public struct ItemDescriptor: Equatable, Sendable {
        public let id: String
        public let tool: CanonicalTool?
        public let isBatchable: Bool

        public init(id: String, tool: CanonicalTool?, isBatchable: Bool) {
            self.id = id
            self.tool = tool
            self.isBatchable = isBatchable
        }
    }

    public struct Group: Equatable, Sendable {
        public let ids: [String]
        public let tool: CanonicalTool?

        public init(ids: [String], tool: CanonicalTool?) {
            self.ids = ids
            self.tool = tool
        }
    }

    /// Coalesces only adjacent, successful same-kind actions. Non-tool rows
    /// and failed/live actions remain individual and break a batch, preserving
    /// chronology and ensuring errors never disappear inside a quiet summary.
    public static func groups(_ items: [ItemDescriptor]) -> [Group] {
        var output: [Group] = []
        var pendingIds: [String] = []
        var pendingTool: CanonicalTool?

        func flush() {
            guard !pendingIds.isEmpty else { return }
            output.append(Group(ids: pendingIds, tool: pendingTool))
            pendingIds.removeAll(keepingCapacity: true)
            pendingTool = nil
        }

        for item in items {
            guard item.isBatchable, let tool = item.tool else {
                flush()
                output.append(Group(ids: [item.id], tool: item.tool))
                continue
            }

            if pendingTool == tool {
                pendingIds.append(item.id)
            } else {
                flush()
                pendingTool = tool
                pendingIds = [item.id]
            }
        }
        flush()
        return output
    }
}
