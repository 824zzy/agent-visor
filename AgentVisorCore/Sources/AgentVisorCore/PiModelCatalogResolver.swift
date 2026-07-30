import Foundation

public struct PiModelCatalogMetadata: Equatable, Sendable {
    public let displayName: String?
    public let contextWindowTokens: Int?

    public init(displayName: String?, contextWindowTokens: Int?) {
        self.displayName = displayName
        self.contextWindowTokens = contextWindowTokens
    }
}

/// Resolves Pi's effective model metadata from its local models-store cache.
/// Provider is part of model identity: different providers may expose the
/// same model id with different names or context windows.
public enum PiModelCatalogResolver {
    public static func metadata(
        catalogData: Data,
        provider: String?,
        modelID: String?
    ) -> PiModelCatalogMetadata? {
        guard let provider, !provider.isEmpty,
              let modelID, !modelID.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
              let providerEntry = root[provider] as? [String: Any],
              let models = providerEntry["models"] as? [[String: Any]],
              let model = models.last(where: { $0["id"] as? String == modelID }) else {
            return nil
        }

        let rawDisplayName = model["name"] as? String
        let displayName = rawDisplayName.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let contextWindow = (model["contextWindow"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        guard displayName != nil || contextWindow != nil else { return nil }
        return PiModelCatalogMetadata(
            displayName: displayName,
            contextWindowTokens: contextWindow
        )
    }

    public static func contextWindowTokens(
        catalogData: Data,
        provider: String?,
        modelID: String?
    ) -> Int? {
        metadata(
            catalogData: catalogData,
            provider: provider,
            modelID: modelID
        )?.contextWindowTokens
    }
}
