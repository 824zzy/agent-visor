// Humanizes a raw Claude model identifier into a short display label.
//
//   "claude-sonnet-4-5-20250929"   -> "Sonnet 4.5"
//   "claude-opus-4-7"              -> "Opus 4.7"
//   "claude-haiku-4-5-20251001"    -> "Haiku 4.5"
//   "claude-sonnet-4-5-20250929[1m]" -> "Sonnet 4.5"
//
// Returns nil for synthetic / internal IDs (anything beginning with "<")
// — Claude Code stamps internal bookkeeping messages with
// "<synthetic>" / "<missing>" model names; we never want those in the UI.

import Foundation

public enum ModelDisplayName {
    public static func format(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("<") { return nil }

        // Strip the "claude-" prefix when present so capitalization
        // works on the family name. Some non-claude model IDs are
        // passed through unchanged.
        let cleaned = raw.hasPrefix("claude-")
            ? String(raw.dropFirst("claude-".count))
            : raw

        let parts = cleaned.split(separator: "-")
        guard parts.count >= 3 else { return raw }

        let family = parts[0].capitalized
        let major = parts[1]
        // The minor component may carry a trailing variant marker
        // like "[1m]" for the 1M-context Sonnet beta — strip it so
        // "Sonnet 4.5" reads cleanly. The 1M variant is surfaced
        // through the context-window number, not the model name.
        let minorWithTag = String(parts[2])
        let minor: String
        if let bracket = minorWithTag.firstIndex(of: "[") {
            minor = String(minorWithTag[..<bracket])
        } else {
            minor = minorWithTag
        }
        return "\(family) \(major).\(minor)"
    }
}
