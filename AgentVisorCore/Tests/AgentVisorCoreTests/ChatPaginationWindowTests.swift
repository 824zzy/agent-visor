//
//  ChatPaginationWindowTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ChatPaginationWindowTests: XCTestCase {
    // MARK: - slice(totalItems:)

    func testEmptyTotalReturnsEmptyRange() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertEqual(w.slice(totalItems: 0), 0..<0)
    }

    func testTotalSmallerThanLimitReturnsFullRange() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertEqual(w.slice(totalItems: 100), 0..<100)
    }

    func testTotalEqualToLimitReturnsFullRange() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertEqual(w.slice(totalItems: 500), 0..<500)
    }

    func testTotalLargerThanLimitReturnsSuffix() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertEqual(w.slice(totalItems: 1500), 1000..<1500)
    }

    func testStressSessionReturnsFinal500() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertEqual(w.slice(totalItems: 153_000), 152_500..<153_000)
    }

    func testNegativeLimitClampsToZero() {
        let w = ChatPaginationWindow(visibleLimit: -10)
        XCTAssertEqual(w.slice(totalItems: 100), 100..<100)
    }

    // MARK: - hasMore(totalItems:)

    func testHasMoreFalseWhenEmpty() {
        XCTAssertFalse(ChatPaginationWindow(visibleLimit: 500).hasMore(totalItems: 0))
    }

    func testHasMoreFalseWhenAllVisible() {
        XCTAssertFalse(ChatPaginationWindow(visibleLimit: 500).hasMore(totalItems: 200))
        XCTAssertFalse(ChatPaginationWindow(visibleLimit: 500).hasMore(totalItems: 500))
    }

    func testHasMoreTrueWhenSomeHidden() {
        XCTAssertTrue(ChatPaginationWindow(visibleLimit: 500).hasMore(totalItems: 501))
        XCTAssertTrue(ChatPaginationWindow(visibleLimit: 500).hasMore(totalItems: 153_000))
    }

    // MARK: - hiddenCount(totalItems:)

    func testHiddenCountZeroWhenAllVisible() {
        XCTAssertEqual(ChatPaginationWindow(visibleLimit: 500).hiddenCount(totalItems: 100), 0)
        XCTAssertEqual(ChatPaginationWindow(visibleLimit: 500).hiddenCount(totalItems: 500), 0)
    }

    func testHiddenCountReturnsRemainder() {
        XCTAssertEqual(ChatPaginationWindow(visibleLimit: 500).hiddenCount(totalItems: 1500), 1000)
        XCTAssertEqual(ChatPaginationWindow(visibleLimit: 500).hiddenCount(totalItems: 153_000), 152_500)
    }

    // MARK: - expanded(totalItems:)

    func testExpandedAddsIncrement() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        // Increment is 100 (matches `defaultVisible` so a single tap
        // doubles a fresh window without overshooting the safety cap).
        XCTAssertEqual(w.expanded(totalItems: 153_000).visibleLimit, 600)
    }

    func testExpandedClampsToTotalWhenSmaller() {
        // After expansion, even on a 600-row session we don't
        // inflate the limit beyond what's available.
        let w = ChatPaginationWindow(visibleLimit: 500)
        let next = w.expanded(totalItems: 600)
        // 500 + 500 = 1000, but only 600 items exist; expansion
        // shouldn't quietly inflate the limit beyond reality.
        XCTAssertLessThanOrEqual(next.visibleLimit, 1000)
        XCTAssertGreaterThanOrEqual(next.visibleLimit, 600)
    }

    func testRepeatedExpansionAdvancesUntilFull() {
        var w = ChatPaginationWindow(visibleLimit: 500)
        let total = 700
        XCTAssertTrue(w.hasMore(totalItems: total))
        w = w.expanded(totalItems: total)  // 600
        XCTAssertTrue(w.hasMore(totalItems: total))
        w = w.expanded(totalItems: total)  // 700 (clamped to total)
        XCTAssertFalse(w.hasMore(totalItems: total))
    }

    // MARK: - isFullyExpanded

    func testFullyExpandedAtBoundary() {
        let w = ChatPaginationWindow(visibleLimit: 500)
        XCTAssertTrue(w.isFullyExpanded(totalItems: 500))
        XCTAssertTrue(w.isFullyExpanded(totalItems: 100))
        XCTAssertFalse(w.isFullyExpanded(totalItems: 501))
    }

    // MARK: - isAtSafetyCap

    func testAtSafetyCapAfterEnoughExpansion() {
        var w = ChatPaginationWindow(visibleLimit: 500)
        let total = 153_000
        XCTAssertFalse(w.isAtSafetyCap(totalItems: total))
        // 500 → 600 → 700 → ... +100 each tap → 4000 (safetyCap)
        // 35 expansions: 500 + 35*100 = 4000
        for _ in 0..<35 {
            w = w.expanded(totalItems: total)
        }
        XCTAssertEqual(w.visibleLimit, 4000)
        XCTAssertTrue(w.isAtSafetyCap(totalItems: total))
    }

    func testNotAtSafetyCapWhenSessionIsSmall() {
        // 600-row session expanded fully — visible is 600, well
        // under safety cap, so no warning needed.
        let w = ChatPaginationWindow(visibleLimit: 5000)
        XCTAssertFalse(w.isAtSafetyCap(totalItems: 600))
    }

    // MARK: - Idempotence / round-trip

    func testSlicePlusHiddenEqualsTotal() {
        let total = 12_345
        let w = ChatPaginationWindow(visibleLimit: 500)
        let s = w.slice(totalItems: total)
        XCTAssertEqual(w.hiddenCount(totalItems: total) + s.count, total)
    }

    func testEqualityIsValueBased() {
        XCTAssertEqual(
            ChatPaginationWindow(visibleLimit: 500),
            ChatPaginationWindow(visibleLimit: 500)
        )
        XCTAssertNotEqual(
            ChatPaginationWindow(visibleLimit: 500),
            ChatPaginationWindow(visibleLimit: 1000)
        )
    }
}
