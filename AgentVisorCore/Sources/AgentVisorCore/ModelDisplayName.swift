// Resolves provider-owned model labels without conflating them with raw IDs.
// Catalog metadata wins. Known GPT and Claude identifiers receive a
// conservative fallback, unknown identifiers remain unchanged, and synthetic
// bookkeeping identifiers are never presented.

import Foundation

public enum ModelDisplayName {
    public static func format(_ raw: String?) -> String? {
        resolve(modelID: raw, catalogDisplayName: nil)
    }

    public static func resolve(
        modelID raw: String?,
        catalogDisplayName: String?
    ) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("<") { return nil }

        if let catalogDisplayName,
           !catalogDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return catalogDisplayName
        }

        return gptFallback(for: raw)
            ?? claudeFallback(for: raw)
            ?? raw
    }

    private static func gptFallback(for raw: String) -> String? {
        guard raw.hasPrefix("gpt-") else { return nil }
        let components = raw.dropFirst("gpt-".count).split(separator: "-")
        guard let version = components.first, !version.isEmpty else { return nil }
        let variants = components.dropFirst().map { $0.capitalized }
        return variants.isEmpty
            ? "GPT-\(version)"
            : "GPT-\(version) \(variants.joined(separator: " "))"
    }

    private static func claudeFallback(for raw: String) -> String? {
        let cleaned = raw.hasPrefix("claude-")
            ? String(raw.dropFirst("claude-".count))
            : raw
        let parts = cleaned.split(separator: "-")
        guard parts.count >= 3,
              ["opus", "sonnet", "haiku"].contains(parts[0].lowercased()) else {
            return nil
        }

        let family = parts[0].capitalized
        let major = parts[1]
        let minorWithTag = String(parts[2])
        let minor = minorWithTag.split(separator: "[").first.map(String.init) ?? minorWithTag
        return "\(family) \(major).\(minor)"
    }
}
