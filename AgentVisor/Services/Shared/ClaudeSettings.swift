//
//  ClaudeSettings.swift
//  AgentVisor
//
//  Reads user-configurable values from ~/.claude/settings.json.
//  Currently exposes the "effortLevel" (xhigh / high / medium / low / xlow)
//  which Claude Code uses for thinking budget.
//

import Foundation
import Combine

@MainActor
final class ClaudeSettings: ObservableObject {
    static let shared = ClaudeSettings()

    @Published private(set) var effortLevel: String?

    private var lastModified: Date?

    private var settingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    private init() {
        refresh()
    }

    /// Reload from disk if the file mtime changed. Cheap to call repeatedly.
    func refresh() {
        let path = settingsPath
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }
        if let last = lastModified, last == modDate { return }
        lastModified = modDate

        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let level = json["effortLevel"] as? String
        if level != effortLevel {
            effortLevel = level
        }
    }
}

/// Static lookup for a model's context window size in tokens.
///
/// Per Anthropic's models overview (https://docs.anthropic.com/en/docs/about-claude/models/overview),
/// the 1M-context models are Opus 4.6, Opus 4.7, and Sonnet 4.6. The Sonnet
/// 4.5 1M-context beta is identified by a `[1m]` suffix on the model ID.
/// Everything else (Haiku 4.5, Sonnet 4.5 default, Opus 4.5, Opus 4.1, and
/// older models) is 200K.
enum ModelContextWindow {
    static func tokens(for modelId: String?) -> Int {
        guard let id = modelId?.lowercased() else { return 200_000 }
        if id.contains("[1m]") { return 1_000_000 }
        if id.contains("opus-4-6") { return 1_000_000 }
        if id.contains("opus-4-7") { return 1_000_000 }
        if id.contains("opus-4-8") { return 1_000_000 }
        if id.contains("sonnet-4-6") { return 1_000_000 }
        return 200_000
    }
}
