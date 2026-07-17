//
//  CanceledUserTurnDetector.swift
//  AgentVisorCore
//
//  Detects which user-turn JSONL rows were canceled before Claude
//  Code produced any productive output. Used to filter canceled user
//  bubbles out of the chat view, mirroring how Codex / Claude Code's
//  own TUIs behave.
//
//  Productive descendants: assistant, tool_use, tool_result,
//  tool_use_result. Non-productive (which Claude Code writes for every
//  user turn even when it never replied): attachment, output_style,
//  compact_boundary, system, etc.
//
//  Algorithm: walk the parent-uuid graph from each productive row up
//  to the root, marking every ancestor as "productive." Any user-type
//  row whose uuid is NOT in the productive set is canceled.
//

import Foundation

/// Minimal flat record of a JSONL line for the cancel-detection
/// algorithm. Caller extracts these from the conversation parser
/// before constructing rich `ChatMessage`s.
public struct JSONLRow: Equatable, Sendable {
    public let uuid: String
    public let parentUuid: String?
    public let type: String

    public init(uuid: String, parentUuid: String?, type: String) {
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.type = type
    }
}

public enum CanceledUserTurnDetector {
    /// Types whose presence proves the model produced output for an
    /// ancestor user turn.
    private static let productiveTypes: Set<String> = [
        "assistant",
        "tool_use",
        "tool_result",
        "tool_use_result",
    ]

    /// Returns the set of `uuid`s belonging to user-type rows whose
    /// JSONL subtree contains NO productive descendant. Caller filters
    /// rendered chat items by checking membership in this set.
    public static func canceledUuids(rows: [JSONLRow]) -> Set<String> {
        guard !rows.isEmpty else { return [] }

        // Index rows by uuid so we can walk parent-uuid chains.
        var byUuid: [String: JSONLRow] = [:]
        byUuid.reserveCapacity(rows.count)
        for row in rows {
            byUuid[row.uuid] = row
        }

        // For each productive row, mark every ancestor (including the
        // row itself) as productive. We follow parentUuid until we
        // hit a missing/nil parent or revisit a uuid already in the
        // set (cheap cycle-guard).
        var productive: Set<String> = []
        productive.reserveCapacity(rows.count)
        for row in rows where productiveTypes.contains(row.type) {
            var cursor: String? = row.uuid
            while let uuid = cursor, !productive.contains(uuid) {
                productive.insert(uuid)
                cursor = byUuid[uuid]?.parentUuid
            }
        }

        // Canceled = user-type AND not in productive set.
        var canceled: Set<String> = []
        for row in rows where row.type == "user" {
            if !productive.contains(row.uuid) {
                canceled.insert(row.uuid)
            }
        }
        return canceled
    }
}
