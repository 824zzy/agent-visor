import Foundation
import AgentVisorCore

/// Passive adapter for Codex's local model catalog. It never creates,
/// refreshes, or mutates Codex-owned files.
enum CodexModelCatalogReader {
    nonisolated static func displayName(for modelID: String?) -> String? {
        let environment = Foundation.ProcessInfo.processInfo.environment
        let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )
        let codexHome: URL
        if let configuredHome, !configuredHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        let catalogURL = codexHome.appendingPathComponent("models_cache.json")
        guard let catalogData = FileManager.default.contents(atPath: catalogURL.path) else {
            return nil
        }
        return CodexModelCatalogResolver.displayName(
            catalogData: catalogData,
            modelID: modelID
        )
    }
}
