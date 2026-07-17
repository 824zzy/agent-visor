//
//  ClaudeTurnGrouperTests.swift
//  AgentVisorCoreTests
//
//  Trailing-marker turn segmentation for Claude Code chat: fold a closed
//  turn's work under the turn_duration header, keep only the final
//  answer, drop intermediate narration, leave live/orphan runs flat.
//

import XCTest
@testable import AgentVisorCore

final class ClaudeTurnGrouperTests: XCTestCase {
    private typealias Cat = ClaudeTurnGrouper.ItemCategory
    private typealias Item = ClaudeTurnGrouper.ItemDescriptor

    private func d(_ id: String, _ c: Cat) -> Item { Item(id: id, category: c) }
    private func group(_ items: [Item]) -> [ClaudeTurnGrouper.GroupedRow] {
        ClaudeTurnGrouper.group(items)
    }
    /// Flatten to a compact "id" / "id[child,child]" form for readable asserts.
    private func shape(_ rows: [ClaudeTurnGrouper.GroupedRow]) -> [String] {
        rows.map { $0.childIds.isEmpty ? $0.parentId : "\($0.parentId)[\($0.childIds.joined(separator: ","))]" }
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertEqual(group([]), [])
    }

    func testStandaloneQAHasNoHeader() {
        // user -> assistant final, no work, no marker yet (or pure text).
        let rows = group([d("u", .prompt), d("a", .assistantText)])
        XCTAssertEqual(shape(rows), ["u", "a"])
    }

    func testCompletedTurnDropsNarrationKeepsFinal() {
        let rows = group([
            d("u", .prompt),
            d("narr", .assistantText),       // narration -> dropped
            d("t1", .work(hasError: false)),
            d("final", .assistantText),      // final answer -> kept
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "final"])
        XCTAssertFalse(rows.contains { $0.parentId == "narr" || $0.childIds.contains("narr") })
    }

    func testMultiBlockTrailingAnswerAllKept() {
        let rows = group([
            d("u", .prompt),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("f2", .assistantText),
            d("f3", .assistantText),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "f1", "f2", "f3"])
    }

    func testPureTextTurnNoHeaderEvenWithMarker() {
        // A turn with prose but no work: keep all text, drop the marker,
        // emit no header.
        let rows = group([
            d("u", .prompt),
            d("a1", .assistantText),
            d("a2", .assistantText),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "a1", "a2"])
        XCTAssertFalse(rows.contains { $0.parentId == "dur" })
    }

    func testTurnEndingInToolHasHeaderNoFinalAnswer() {
        let rows = group([
            d("u", .prompt),
            d("narr", .assistantText),
            d("t1", .work(hasError: false)),
            d("t2", .work(hasError: false)),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1,t2]"])
    }

    func testInterruptedCountsAsWork() {
        let rows = group([
            d("u", .prompt),
            d("int", .work(hasError: true)),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[int]"])
        XCTAssertTrue(rows.first { $0.parentId == "dur" }!.hasError)
    }

    func testThinkingOnlyTurnFoldsUnderHeader() {
        let rows = group([
            d("u", .prompt),
            d("think", .work(hasError: false)),
            d("final", .assistantText),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[think]", "final"])
    }

    func testTwoTurnsPreserveOrderAndProduceTwoHeaders() {
        let rows = group([
            d("u1", .prompt),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("dur1", .turnMarker),
            d("u2", .prompt),
            d("t2", .work(hasError: false)),
            d("f2", .assistantText),
            d("dur2", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u1", "dur1[t1]", "f1", "u2", "dur2[t2]", "f2"])
    }

    func testRecapAndCompactBoundaryStayStandalone() {
        let rows = group([
            d("recap", .sessionLevel),
            d("u", .prompt),
            d("t1", .work(hasError: false)),
            d("compact", .sessionLevel),     // sits between work and final
            d("final", .assistantText),
            d("dur", .turnMarker),
        ])
        // session-level items never fold; header still carries t1.
        XCTAssertEqual(shape(rows), ["recap", "u", "dur[t1]", "compact", "final"])
    }

    func testInteractiveItemNeverFoldsInLiveTurn() {
        // Regression: an AskUserQuestion at the tail of a live turn must
        // stay a standalone, visible row — never folded into "Working…"
        // or counted as a step. Work before it still folds; narration
        // before the last work is dropped.
        let liveHdr = "t1" + ClaudeTurnGrouper.liveHeaderSuffix
        let rows = group([
            d("u", .prompt),
            d("narr", .assistantText),
            d("t1", .work(hasError: false)),
            d("ask", .interactive),
        ])
        XCTAssertEqual(shape(rows), ["u", "\(liveHdr)[t1]", "ask"])
        XCTAssertFalse(rows.first { $0.parentId == liveHdr }!.childIds.contains("ask"))
    }

    func testInteractiveItemStandaloneInCompletedTurn() {
        // An interactive item mid-turn stays standalone; it doesn't fold
        // and doesn't move the narration/final boundary (final still kept).
        let rows = group([
            d("u", .prompt),
            d("t1", .work(hasError: false)),
            d("ask", .interactive),
            d("final", .assistantText),
            d("dur", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "ask", "final"])
    }

    func testInteractiveOnlyTurnHasNoHeader() {
        // A turn whose only non-prompt content is interactive → no header,
        // the prompt + interactive row both visible.
        let rows = group([
            d("u", .prompt),
            d("ask", .interactive),
        ])
        XCTAssertEqual(shape(rows), ["u", "ask"])
        XCTAssertFalse(rows.contains { !$0.childIds.isEmpty })
    }

    func testLiveTrailingTurnFoldsUnderSyntheticHeader() {
        // Closed turn, then an open turn still streaming (no marker). The
        // live turn folds too: narration dropped, work under a synthetic
        // "Working…" header (id = first work id + liveHeaderSuffix).
        let liveHdr = "t2" + ClaudeTurnGrouper.liveHeaderSuffix
        let rows = group([
            d("u1", .prompt),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("dur1", .turnMarker),
            d("u2", .prompt),
            d("narr2", .assistantText),   // live narration -> dropped
            d("t2", .work(hasError: false)),
        ])
        XCTAssertEqual(shape(rows), ["u1", "dur1[t1]", "f1", "u2", "\(liveHdr)[t2]"])
        // closed-turn header not live; live-turn header flagged.
        XCTAssertFalse(rows.first { $0.parentId == "dur1" }!.isLive)
        XCTAssertTrue(rows.first { $0.parentId == liveHdr }!.isLive)
    }

    func testLiveTrailingTextAfterWorkIsKept() {
        // Live turn whose latest streamed block is text after a tool —
        // kept (prominent), like a completed turn's final answer.
        let liveHdr = "t1" + ClaudeTurnGrouper.liveHeaderSuffix
        let rows = group([
            d("u", .prompt),
            d("narr", .assistantText),
            d("t1", .work(hasError: false)),
            d("latest", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "\(liveHdr)[t1]", "latest"])
    }

    func testLivePureTextTurnHasNoHeader() {
        // Live turn with prose but no work yet → flat, no synthetic header.
        let rows = group([
            d("u", .prompt),
            d("a1", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "a1"])
        XCTAssertFalse(rows.contains { $0.isLive })
    }

    func testLeadingOrphanWithTrailingMarkerStillFolds() {
        // Pagination cut: window starts mid-turn (prompt scrolled above),
        // but the closing marker is still present. A marker always closes
        // its preceding run, so this folds as a normal closed turn — the
        // only genuinely-flat case is the marker-less trailing live run.
        let rows = group([
            d("t0", .work(hasError: false)),     // orphan work, no opening prompt
            d("f0", .assistantText),
            d("dur0", .turnMarker),
        ])
        XCTAssertEqual(shape(rows), ["dur0[t0]", "f0"])
    }

    func testToolErrorSetsHasErrorAndStepCount() {
        let rows = group([
            d("u", .prompt),
            d("t1", .work(hasError: false)),
            d("t2", .work(hasError: true)),
            d("t3", .work(hasError: false)),
            d("final", .assistantText),
            d("dur", .turnMarker),
        ])
        let header = rows.first { $0.parentId == "dur" }!
        XCTAssertEqual(header.childIds, ["t1", "t2", "t3"])
        XCTAssertEqual(header.stepCount, 3)
        XCTAssertTrue(header.hasError)
    }
}
