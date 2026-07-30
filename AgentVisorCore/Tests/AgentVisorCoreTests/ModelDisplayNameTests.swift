import XCTest
@testable import AgentVisorCore

final class ModelDisplayNameTests: XCTestCase {
    func testSonnetFullID() {
        XCTAssertEqual(ModelDisplayName.format("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testOpus() {
        XCTAssertEqual(ModelDisplayName.format("claude-opus-4-7"), "Opus 4.7")
    }

    func testHaikuDated() {
        XCTAssertEqual(ModelDisplayName.format("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testOneMillionContextVariantStripsMarker() {
        XCTAssertEqual(ModelDisplayName.format("claude-sonnet-4-5-20250929[1m]"), "Sonnet 4.5")
    }

    func testSyntheticReturnsNil() {
        XCTAssertNil(ModelDisplayName.format("<synthetic>"))
        XCTAssertNil(ModelDisplayName.format("<missing>"))
    }

    func testEmptyAndNil() {
        XCTAssertNil(ModelDisplayName.format(nil))
        XCTAssertNil(ModelDisplayName.format(""))
    }

    func testGPTWithoutVariantPreservesBrand() {
        XCTAssertEqual(ModelDisplayName.format("gpt-4"), "GPT-4")
    }

    func testGPTFallbackPreservesBrandVersionAndVariantWords() {
        XCTAssertEqual(ModelDisplayName.format("gpt-5.6-sol"), "GPT-5.6 Sol")
        XCTAssertEqual(ModelDisplayName.format("gpt-5.3-codex-spark"), "GPT-5.3 Codex Spark")
    }

    func testUnknownIdentifierRemainsUnchanged() {
        XCTAssertEqual(ModelDisplayName.format("vendor-ultra-2026"), "vendor-ultra-2026")
    }

    func testProviderCatalogDisplayNameWinsVerbatim() {
        XCTAssertEqual(
            ModelDisplayName.resolve(
                modelID: "gpt-5.6-sol",
                catalogDisplayName: "GPT-5.6 Sol"
            ),
            "GPT-5.6 Sol"
        )
    }
}
