//
//  CodexConversationSummary.swift
//  AgentVisor
//
//  Lightweight head+tail summary parser for Codex rollout JSONL.
//

import Foundation
import AgentVisorCore

actor CodexConversationSummary {
    static let shared = CodexConversationSummary()

    private struct CachedInfo {
        let signature: CodexRolloutFileSignature
        let info: ConversationInfo
        let marker: TurnMarker
        let turnContextScan: CodexTurnContextScanState?
    }

    private var cache: [String: CachedInfo] = [:]

    private init() {}

    func parse(sessionId: String, rolloutPath: String?) async -> ConversationInfo {
        guard let path = rolloutPath,
              !path.isEmpty,
              let signature = Self.signature(path: path) else {
            cache.removeValue(forKey: sessionId)
            return CodexConversationInfoBuilder.empty()
        }

        let cached = cache[sessionId]
        if let cached,
           cached.signature == signature {
            return cached.info
        }

        guard let summary = CodexRolloutSummaryReader.read(
            path: path,
            previousTurnContextScan: cached?.turnContextScan
        ) else {
            cache.removeValue(forKey: sessionId)
            return CodexConversationInfoBuilder.empty()
        }

        let parsed = summary.transcript
        let info = CodexConversationInfoBuilder.build(from: parsed)
        cache[sessionId] = CachedInfo(
            signature: signature,
            info: info,
            marker: parsed.lastTurnMarker,
            turnContextScan: summary.turnContextScan
        )
        return info
    }

    func lastTurnMarker(for sessionId: String) -> TurnMarker {
        cache[sessionId]?.marker ?? .none
    }

    private static func signature(path: String) -> CodexRolloutFileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return CodexRolloutFileSignature(
            path: path,
            byteCount: size.int64Value
        )
    }
}
