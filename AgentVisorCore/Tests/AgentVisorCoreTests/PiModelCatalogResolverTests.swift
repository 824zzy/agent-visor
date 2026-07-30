import XCTest
@testable import AgentVisorCore

final class PiModelCatalogResolverTests: XCTestCase {
    func testResolvesCanonicalDisplayNameAndContextByProviderAndModelID() {
        let catalog = """
        {
          "openai-codex": {
            "models": [
              {
                "id":"gpt-5.6-sol",
                "name":"GPT-5.6 Sol",
                "provider":"openai-codex",
                "contextWindow":272000
              }
            ]
          }
        }
        """

        XCTAssertEqual(
            PiModelCatalogResolver.metadata(
                catalogData: Data(catalog.utf8),
                provider: "openai-codex",
                modelID: "gpt-5.6-sol"
            ),
            PiModelCatalogMetadata(
                displayName: "GPT-5.6 Sol",
                contextWindowTokens: 272_000
            )
        )
    }

    func testResolvesContextWindowByProviderAndModelID() {
        let catalog = """
        {
          "openai-codex": {
            "models": [
              {"id":"gpt-5.6-sol","provider":"openai-codex","contextWindow":272000}
            ]
          },
          "other": {
            "models": [
              {"id":"gpt-5.6-sol","provider":"other","contextWindow":128000}
            ]
          }
        }
        """

        XCTAssertEqual(
            PiModelCatalogResolver.contextWindowTokens(
                catalogData: Data(catalog.utf8),
                provider: "openai-codex",
                modelID: "gpt-5.6-sol"
            ),
            272_000
        )
    }
}
