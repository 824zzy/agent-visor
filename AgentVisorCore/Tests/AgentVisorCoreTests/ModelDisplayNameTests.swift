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

    func testNonClaudeIdPassesThroughWhenUnparseable() {
        XCTAssertEqual(ModelDisplayName.format("gpt-4"), "gpt-4")
    }

    func testNonClaudePrefixedThreePart() {
        XCTAssertEqual(ModelDisplayName.format("gpt-4-turbo"), "Gpt 4.turbo")
    }
}
