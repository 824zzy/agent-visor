import XCTest
@testable import AgentVisorCore

final class CodexModelCatalogResolverTests: XCTestCase {
    func testResolvesCanonicalDisplayNameByModelSlug() {
        let catalog = """
        {
          "models": [
            {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol"},
            {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra"}
          ]
        }
        """

        XCTAssertEqual(
            CodexModelCatalogResolver.displayName(
                catalogData: Data(catalog.utf8),
                modelID: "gpt-5.6-sol"
            ),
            "GPT-5.6-Sol"
        )
    }

    func testPartialUnrelatedEntryDoesNotHideAValidDisplayName() {
        let catalog = """
        {
          "models": [
            {"slug":"experimental-without-a-label"},
            {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol"}
          ]
        }
        """

        XCTAssertEqual(
            CodexModelCatalogResolver.displayName(
                catalogData: Data(catalog.utf8),
                modelID: "gpt-5.6-sol"
            ),
            "GPT-5.6-Sol"
        )
    }
}
