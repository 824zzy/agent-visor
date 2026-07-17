import XCTest
@testable import AgentVisorCore

final class SyntheticAssistantFilterTests: XCTestCase {

    // MARK: - Drops

    func testDropsSyntheticAssistant() {
        // The canonical case: claude-code's interrupt-handler injection.
        // JSONL row carries type=assistant + model=<synthetic>.
        XCTAssertTrue(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "<synthetic>"))
    }

    func testDropsAnyBracketedSentinelOnAssistant() {
        // The `<` prefix rule is deliberately broad so future synthetic
        // sentinels (e.g. a hypothetical `<rate_limit>`) drop without
        // needing a code change. Real model ids never start with `<`.
        XCTAssertTrue(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "<rate_limit>"))
        XCTAssertTrue(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "<anything>"))
    }

    // MARK: - Keeps

    func testKeepsRealAssistantModel() {
        // Real assistant turns must pass through. Spot-check the live
        // model ids claude-code ships.
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "claude-opus-4-7"))
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "claude-sonnet-4-6"))
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: "claude-haiku-4-5-20251001"))
    }

    func testKeepsAssistantWithoutModel() {
        // Defensive: a missing model field is not, on its own, a signal
        // for synthetic injection. Pass it through and let downstream
        // handle it.
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: nil))
    }

    func testKeepsAssistantWithEmptyModel() {
        // Empty string doesn't start with `<`, so it's not synthetic.
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "assistant", model: ""))
    }

    func testKeepsUserRowEvenWithBracketModel() {
        // The bracket-model check is scoped to assistants. A user row
        // somehow carrying a synthetic-looking model field is not
        // claude-code's interrupt padding — leave it visible.
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "user", model: "<synthetic>"))
    }

    func testKeepsSystemRow() {
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "system", model: "<synthetic>"))
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "system", model: nil))
    }

    func testKeepsUnknownRole() {
        // Forward-compatibility: an unrecognized role shouldn't be
        // silently filtered. Only "assistant" triggers the drop.
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "tool", model: "<synthetic>"))
    }

    func testRoleMatchIsExact() {
        // No case folding, no trimming. The JSONL `type` field is
        // strictly lowercase "assistant".
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "Assistant", model: "<synthetic>"))
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: "ASSISTANT", model: "<synthetic>"))
        XCTAssertFalse(SyntheticAssistantFilter.shouldDrop(role: " assistant", model: "<synthetic>"))
    }
}
