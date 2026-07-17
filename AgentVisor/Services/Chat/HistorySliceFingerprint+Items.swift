//
//  HistorySliceFingerprint+Items.swift
//  AgentVisor
//
//  App-side factory for the Core `HistorySliceFingerprint` that walks
//  `[ChatHistoryItem]` to compute a tail-window-aware hash.
//
//  Lives in the app target (not Core) because `ChatHistoryItem` and
//  `ChatHistoryItemType` are app-side types — Core stays UI-free and
//  doesn't depend on chat presentation models.
//
//  Why a tail-window factory at all: a (count, lastId)-only
//  fingerprint silently swallowed in-place mutations on assistant
//  text items whose position in the array got shifted by a trailing
//  tool placeholder. The streaming UI then froze until the next
//  user turn forced a count change. See the matching upstream
//  fingerprint in `ChatHistoryManager.chatItemsFingerprint` for the
//  parallel fix.
//

import AgentVisorCore
import Foundation

extension HistorySliceFingerprint {
    /// Tail-aware fingerprint of an ordered chat items slice.
    /// Streaming text growth and toolCall status flips at the last
    /// `HistorySliceFingerprint.tailWindow` positions all flip the
    /// hash; appends always do (count changes).
    static func from(items: [ChatHistoryItem]) -> HistorySliceFingerprint {
        var hasher = Hasher()
        let start = max(0, items.count - HistorySliceFingerprint.tailWindow)
        for idx in start..<items.count {
            let item = items[idx]
            hasher.combine(item.id)
            switch item.type {
            case .user(let s), .assistant(let s), .thinking(let s),
                 .recap(let s), .localCommandOutput(let s):
                hasher.combine(s.count / 64)
            case .image(let image):
                hasher.combine(image.source.rawValue)
                hasher.combine(image.value.count)
            case .toolCall(let tool):
                hasher.combine(tool.status.description)
                hasher.combine(tool.subagentTools.count)
            case .interrupted, .turnDuration, .compactBoundary:
                break
            }
        }
        return HistorySliceFingerprint(
            count: items.count,
            lastId: items.last?.id ?? "",
            tailHash: hasher.finalize()
        )
    }
}
