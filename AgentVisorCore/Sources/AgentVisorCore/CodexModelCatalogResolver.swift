import Foundation

/// Resolves human-facing names from Codex's read-only models cache while
/// keeping rollout model slugs as the internal identity.
public enum CodexModelCatalogResolver {
    public static func displayName(
        catalogData: Data,
        modelID: String?
    ) -> String? {
        guard let modelID, !modelID.isEmpty,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogData),
              let model = catalog.models.last(where: { $0.slug == modelID }),
              let displayName = model.displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return displayName
    }

    private struct Catalog: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let slug: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
        }
    }
}
