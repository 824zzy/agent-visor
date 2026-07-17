import XCTest
@testable import AgentVisorCore

final class PillTitleDisambiguatorTests: XCTestCase {

    private func item(_ id: String, _ title: String) -> PillTitleDisambiguator.Item {
        PillTitleDisambiguator.Item(id: id, title: title)
    }

    func testEmptyListReturnsEmptyMap() {
        XCTAssertEqual(PillTitleDisambiguator.suffixes(for: []), [:])
    }

    func testSingleItemReturnsEmptyMap() {
        let result = PillTitleDisambiguator.suffixes(for: [item("abc12345", "codebase")])
        XCTAssertEqual(result, [:])
    }

    func testUniqueTitlesReturnEmptyMap() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("abc12345", "alpha"),
            item("def67890", "bravo"),
            item("ghi13579", "charlie")
        ])
        XCTAssertEqual(result, [:])
    }

    func testTwoCollidingTitlesBothGetSuffixes() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("abc12345", "codebase"),
            item("def67890", "codebase")
        ])
        XCTAssertEqual(result, [
            "abc12345": "abc1",
            "def67890": "def6"
        ])
    }

    func testThreeItemsTwoCollideOnlyCollidersGetSuffixes() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("aaa11111", "codebase"),
            item("bbb22222", "codebase"),
            item("ccc33333", "other")
        ])
        XCTAssertEqual(result, [
            "aaa11111": "aaa1",
            "bbb22222": "bbb2"
        ])
    }

    func testAllIdenticalTitlesAllGetSuffixes() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("aaa11111", "x"),
            item("bbb22222", "x"),
            item("ccc33333", "x"),
            item("ddd44444", "x")
        ])
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result["aaa11111"], "aaa1")
        XCTAssertEqual(result["ccc33333"], "ccc3")
    }

    func testEmptyTitlesCollideToo() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("aaa11111", ""),
            item("bbb22222", "")
        ])
        XCTAssertEqual(result.count, 2)
    }

    func testShortIDStillProducesSuffix() {
        let result = PillTitleDisambiguator.suffixes(for: [
            item("ab", "codebase"),
            item("cd", "codebase")
        ])
        // First 4 chars of "ab" is just "ab"
        XCTAssertEqual(result["ab"], "ab")
        XCTAssertEqual(result["cd"], "cd")
    }

    func testMixedScenario() {
        // Two groups of colliders + a singleton
        let result = PillTitleDisambiguator.suffixes(for: [
            item("1111aaaa", "alpha"),
            item("2222bbbb", "alpha"),
            item("3333cccc", "bravo"),
            item("4444dddd", "bravo"),
            item("5555eeee", "lonely")
        ])
        XCTAssertEqual(result.count, 4)
        XCTAssertNil(result["5555eeee"])
        XCTAssertEqual(result["1111aaaa"], "1111")
        XCTAssertEqual(result["3333cccc"], "3333")
    }
}
