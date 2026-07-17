import Foundation

public enum ProjectAwarePillOrder {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let projectKey: String?
        /// Preserved for caller compatibility, but intentionally ignored by
        /// ordering: agent/source diversity must not move older sessions ahead
        /// of newer sessions inside the same project and priority tier.
        public let surfaceKey: String?
        public let priority: Int
        public let sortDate: Date

        public init(
            id: String,
            projectKey: String?,
            surfaceKey: String? = nil,
            priority: Int,
            sortDate: Date
        ) {
            self.id = id
            self.projectKey = projectKey
            self.surfaceKey = surfaceKey
            self.priority = priority
            self.sortDate = sortDate
        }
    }

    public static func orderedIds(for candidates: [Candidate]) -> [String] {
        let priorities = Set(candidates.map(\.priority)).sorted()
        return priorities.flatMap { priority in
            roundRobinProjects(candidates.filter { $0.priority == priority }).map(\.id)
        }
    }

    private static func roundRobinProjects(_ candidates: [Candidate]) -> [Candidate] {
        let grouped = Dictionary(grouping: candidates, by: projectBucket)
        var buckets = grouped.map { key, values in
            Bucket(
                key: key,
                items: values.sorted(by: candidatePrecedes)
            )
        }.sorted(by: bucketPrecedes)

        var ordered: [Candidate] = []
        while buckets.contains(where: { !$0.items.isEmpty }) {
            for index in buckets.indices where !buckets[index].items.isEmpty {
                ordered.append(buckets[index].items.removeFirst())
            }
        }
        return ordered
    }

    private struct Bucket {
        let key: String
        var items: [Candidate]

        var newest: Date {
            items.map(\.sortDate).max() ?? .distantPast
        }
    }

    private static func projectBucket(_ candidate: Candidate) -> String {
        guard let key = candidate.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return "other"
        }
        return key
    }

    private static func bucketPrecedes(_ lhs: Bucket, _ rhs: Bucket) -> Bool {
        if lhs.newest != rhs.newest { return lhs.newest > rhs.newest }
        return lhs.key < rhs.key
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
        return lhs.id < rhs.id
    }
}
