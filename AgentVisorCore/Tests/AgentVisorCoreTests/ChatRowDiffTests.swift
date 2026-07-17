//
//  ChatRowDiffTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ChatRowDiffTests: XCTestCase {
    // MARK: - empty / identity

    func testEmptyToEmptyIsNoop() {
        let d = ChatRowDiff.compute(old: [], new: [])
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions.count, 0)
        XCTAssertTrue(d.isNoop)
    }

    func testIdenticalArraysIsNoop() {
        let ids = ["a", "b", "c", "d"]
        let d = ChatRowDiff.compute(old: ids, new: ids)
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions.count, 0)
        XCTAssertTrue(d.isNoop)
    }

    // MARK: - initial load (empty -> N)

    func testInitialLoadInsertsAll() {
        let d = ChatRowDiff.compute(old: [], new: ["a", "b", "c"])
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([0, 1, 2]))
    }

    // MARK: - append (most common case in streaming chat)

    func testAppendOneInsertsAtTail() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "c"],
            new: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([3]))
    }

    func testAppendManyInsertsAtTailRange() {
        let d = ChatRowDiff.compute(
            old: ["a", "b"],
            new: ["a", "b", "c", "d", "e"]
        )
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([2, 3, 4]))
    }

    // MARK: - prepend (load-earlier case)

    func testPrependInsertsAtHead() {
        let d = ChatRowDiff.compute(
            old: ["c", "d"],
            new: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([0, 1]))
    }

    func testLoadEarlierBigBlock() {
        // 100 earlier rows loaded above the current 100-row window.
        let oldIds = (100..<200).map { "id-\($0)" }
        let newIds = (0..<200).map { "id-\($0)" }
        let d = ChatRowDiff.compute(old: oldIds, new: newIds)
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet(integersIn: 0..<100))
    }

    // MARK: - tail mutation (echo -> real id swap)

    func testReplaceLastRowRemovesAndInsertsAtTail() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "echo-1"],
            new: ["a", "b", "real-1"]
        )
        XCTAssertEqual(d.removals, IndexSet([2]))
        XCTAssertEqual(d.insertions, IndexSet([2]))
    }

    func testReplaceLastTwoRows() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "echo-q", "echo-r"],
            new: ["a", "b", "real-q", "real-r"]
        )
        XCTAssertEqual(d.removals, IndexSet([2, 3]))
        XCTAssertEqual(d.insertions, IndexSet([2, 3]))
    }

    // MARK: - middle remove (rare but possible: dedup)

    func testRemoveMiddleRow() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "c", "d"],
            new: ["a", "c", "d"]
        )
        XCTAssertEqual(d.removals, IndexSet([1]))
        XCTAssertEqual(d.insertions.count, 0)
    }

    func testRemoveMiddleBlock() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "c", "d", "e"],
            new: ["a", "e"]
        )
        XCTAssertEqual(d.removals, IndexSet([1, 2, 3]))
        XCTAssertEqual(d.insertions.count, 0)
    }

    // MARK: - middle insert

    func testInsertInMiddle() {
        let d = ChatRowDiff.compute(
            old: ["a", "d"],
            new: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([1, 2]))
    }

    // MARK: - full replace (/compact case)

    func testFullReplaceRemovesAllInsertsAll() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "c"],
            new: ["x", "y"]
        )
        XCTAssertEqual(d.removals, IndexSet([0, 1, 2]))
        XCTAssertEqual(d.insertions, IndexSet([0, 1]))
    }

    func testClearAllRemovesAll() {
        let d = ChatRowDiff.compute(old: ["a", "b", "c"], new: [])
        XCTAssertEqual(d.removals, IndexSet([0, 1, 2]))
        XCTAssertEqual(d.insertions.count, 0)
    }

    // MARK: - prefix preserved + middle change + suffix preserved

    func testReplaceMiddleBlock() {
        let d = ChatRowDiff.compute(
            old: ["a", "b", "old1", "old2", "y", "z"],
            new: ["a", "b", "new1", "y", "z"]
        )
        XCTAssertEqual(d.removals, IndexSet([2, 3]))
        XCTAssertEqual(d.insertions, IndexSet([2]))
    }

    // MARK: - applying the diff produces the new array

    func testApplyingDiffYieldsNewArray() {
        // Property check: starting from old, removing
        // d.removals (in descending order so indices stay valid)
        // and inserting d.insertions's ids at the right positions
        // should produce new.
        let cases: [(old: [String], new: [String])] = [
            ([], []),
            ([], ["a"]),
            (["a"], []),
            (["a", "b", "c"], ["a", "b", "c", "d"]),
            (["a", "b", "c"], ["a", "b", "real-c"]),
            (["c", "d"], ["a", "b", "c", "d"]),
            (["a", "b", "c", "d"], ["a", "d"]),
            (["a", "b", "c"], ["x", "y"]),
        ]
        for (old, new) in cases {
            let d = ChatRowDiff.compute(old: old, new: new)
            // Apply removals first (descending so indices stay valid),
            // then insertions ascending.
            var working = old
            for idx in d.removals.sorted(by: >) {
                working.remove(at: idx)
            }
            for idx in d.insertions.sorted() {
                working.insert(new[idx], at: idx)
            }
            XCTAssertEqual(working, new, "old=\(old) new=\(new) yielded \(working)")
        }
    }

    // MARK: - performance bound (linear, not quadratic)

    func testLargeAppendIsLinear() {
        // 10k existing rows + 1 appended row should produce a tiny
        // diff. The differ should NOT do an O(N²) comparison; the
        // expected ops count is 1.
        let oldIds = (0..<10_000).map { "id-\($0)" }
        var newIds = oldIds
        newIds.append("id-tail")
        let d = ChatRowDiff.compute(old: oldIds, new: newIds)
        XCTAssertEqual(d.removals.count, 0)
        XCTAssertEqual(d.insertions, IndexSet([10_000]))
    }
}
