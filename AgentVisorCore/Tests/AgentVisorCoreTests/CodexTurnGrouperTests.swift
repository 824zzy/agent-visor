//
//  CodexTurnGrouperTests.swift
//  AgentVisorCoreTests
//
//  Prompt-boundary turn segmentation for Codex chat: each user prompt
//  opens a turn, work folds under a LEADING "Worked …" header, interim
//  narration folds as collapsible children (NOT dropped), only the
//  trailing final answer stays prominent. The live (last, marker-less,
//  processing) turn folds under a synthetic "Working…" header.
//

import XCTest
@testable import AgentVisorCore

final class CodexTurnGrouperTests: XCTestCase {
    private typealias Cat = CodexTurnGrouper.ItemCategory
    private typealias Item = CodexTurnGrouper.ItemDescriptor

    private func d(_ id: String, _ c: Cat) -> Item { Item(id: id, category: c) }
    private func group(_ items: [Item], processing: Bool = false) -> [CodexTurnGrouper.GroupedRow] {
        CodexTurnGrouper.group(items, sessionIsProcessing: processing)
    }
    /// Flatten to a compact "id" / "id[child,child]" form for readable asserts.
    private func shape(_ rows: [CodexTurnGrouper.GroupedRow]) -> [String] {
        rows.map { $0.childIds.isEmpty ? $0.parentId : "\($0.parentId)[\($0.childIds.joined(separator: ","))]" }
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertEqual(group([]), [])
    }

    func testStandaloneQAHasNoHeader() {
        // prompt + final answer, no work, no marker → flat.
        let rows = group([d("u", .prompt), d("a", .assistantText)])
        XCTAssertEqual(shape(rows), ["u", "a"])
        XCTAssertFalse(rows.contains { !$0.childIds.isEmpty })
    }

    func testCompletedTurnLeadingMarkerFoldsCommentaryKeepsFinal() {
        // Codex order: prompt → leading turnDuration → commentary(work) →
        // tool(work) → final. Commentary FOLDS (not dropped); final kept.
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("comm", .work(hasError: false)),   // commentary → folded child
            d("t1", .work(hasError: false)),
            d("final", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[comm,t1]", "final"])
        // header id IS the real turn_duration id (carries duration downstream).
        XCTAssertEqual(rows.first { $0.childIds == ["comm", "t1"] }!.parentId, "dur")
    }

    func testMultiBlockTrailingAnswerAllKept() {
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("f2", .assistantText),
            d("f3", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "f1", "f2", "f3"])
    }

    func testPureTextTurnNoHeaderEvenWithMarker() {
        // prose but no work: keep text, drop marker, no header.
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("a1", .assistantText),
            d("a2", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "a1", "a2"])
        XCTAssertFalse(rows.contains { $0.parentId == "dur" })
    }

    func testTurnEndingInToolHasHeaderNoFinalAnswer() {
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("comm", .work(hasError: false)),
            d("t1", .work(hasError: false)),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[comm,t1]"])
    }

    func testInterimAssistantTextBeforeWorkIsFolded() {
        // A non-final assistant block that precedes a later work item folds
        // as a child so only the trailing answer stays prominent.
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("interim", .assistantText),   // before later work → folded
            d("t1", .work(hasError: false)),
            d("final", .assistantText),     // trailing → kept
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[interim,t1]", "final"])
    }

    func testTwoTurnsPreserveOrderAndProduceTwoHeaders() {
        let rows = group([
            d("u1", .prompt),
            d("dur1", .turnMarker),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("u2", .prompt),
            d("dur2", .turnMarker),
            d("t2", .work(hasError: false)),
            d("f2", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u1", "dur1[t1]", "f1", "u2", "dur2[t2]", "f2"])
    }

    func testAbortedTurnNoMarkerNotProcessingUsesStaticSyntheticHeader() {
        // task aborted: work, no duration block, session NOT processing →
        // static header keyed on first work id + abortedHeaderSuffix.
        let hdr = "t1" + CodexTurnGrouper.abortedHeaderSuffix
        let rows = group([
            d("u", .prompt),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
        ], processing: false)
        XCTAssertEqual(shape(rows), ["u", "\(hdr)[t1]", "f1"])
        XCTAssertFalse(rows.first { $0.parentId == hdr }!.isLive)
    }

    func testLiveTurnNoMarkerProcessingFoldsUnderWorkingHeader() {
        // The screenshot case: last turn, no duration, session processing →
        // live synthetic header.
        // Header id keys on the FIRST work item (commentary `comm` here).
        let hdr = "comm" + CodexTurnGrouper.liveHeaderSuffix
        let rows = group([
            d("u", .prompt),
            d("comm", .work(hasError: false)),
            d("t1", .work(hasError: false)),
        ], processing: true)
        XCTAssertEqual(shape(rows), ["u", "\(hdr)[comm,t1]"])
        XCTAssertTrue(rows.first { $0.parentId == hdr }!.isLive)
    }

    func testLastTurnWithDurationIsNeverLiveEvenWhenProcessing() {
        // A duration block means the turn ended; processing flag must not
        // make it live (a new turn would open with a fresh prompt).
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
        ], processing: true)
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "f1"])
        XCTAssertFalse(rows.first { $0.parentId == "dur" }!.isLive)
    }

    func testLiveTrailingTextAfterWorkIsKept() {
        let hdr = "comm" + CodexTurnGrouper.liveHeaderSuffix
        let rows = group([
            d("u", .prompt),
            d("comm", .work(hasError: false)),
            d("t1", .work(hasError: false)),
            d("latest", .assistantText),
        ], processing: true)
        XCTAssertEqual(shape(rows), ["u", "\(hdr)[comm,t1]", "latest"])
    }

    func testLivePromptOnlyTurnHasNoHeader() {
        // Last turn is just a prompt (no work yet), session processing →
        // no empty "Working…" header.
        let rows = group([
            d("u1", .prompt),
            d("dur1", .turnMarker),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
            d("u2", .prompt),
        ], processing: true)
        XCTAssertEqual(shape(rows), ["u1", "dur1[t1]", "f1", "u2"])
        XCTAssertFalse(rows.contains { $0.isLive })
    }

    func testLeadingOrphanBeforeFirstPromptFoldsAsItsOwnTurn() {
        // Pagination cut: window starts mid-turn (prompt scrolled above).
        // With a leading marker present it folds as a normal completed turn.
        let rows = group([
            d("dur0", .turnMarker),
            d("t0", .work(hasError: false)),
            d("f0", .assistantText),
            d("u1", .prompt),
            d("dur1", .turnMarker),
            d("t1", .work(hasError: false)),
            d("f1", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["dur0[t0]", "f0", "u1", "dur1[t1]", "f1"])
    }

    func testInteractiveItemStaysStandaloneAndDoesNotMoveBoundary() {
        // An AskUserQuestion / pending-approval item never folds and doesn't
        // move the work/answer boundary (final still kept prominent).
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("t1", .work(hasError: false)),
            d("ask", .interactive),
            d("final", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["u", "dur[t1]", "ask", "final"])
        XCTAssertFalse(rows.first { $0.parentId == "dur" }!.childIds.contains("ask"))
    }

    func testSessionLevelStaysStandalone() {
        let rows = group([
            d("recap", .sessionLevel),
            d("u", .prompt),
            d("dur", .turnMarker),
            d("t1", .work(hasError: false)),
            d("final", .assistantText),
        ])
        XCTAssertEqual(shape(rows), ["recap", "u", "dur[t1]", "final"])
    }

    func testToolErrorSetsHasErrorAndStepCount() {
        let rows = group([
            d("u", .prompt),
            d("dur", .turnMarker),
            d("t1", .work(hasError: false)),
            d("t2", .work(hasError: true)),
            d("t3", .work(hasError: false)),
            d("final", .assistantText),
        ])
        let header = rows.first { $0.parentId == "dur" }!
        XCTAssertEqual(header.childIds, ["t1", "t2", "t3"])
        XCTAssertEqual(header.stepCount, 3)
        XCTAssertTrue(header.hasError)
    }
}
