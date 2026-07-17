//
//  CanceledUserTurnDetectorTests.swift
//  AgentVisorCoreTests
//
//  TDD tests for "which user-turn JSONL rows were canceled before
//  Claude could reply?" — used to hide canceled user bubbles from the
//  chat view, matching how Codex / Claude Code's own TUI behaves.
//
//  Algorithm: a user turn's `uuid` is "canceled" if no descendant in
//  the parent-uuid graph has a productive type (assistant / tool_use
//  / tool_result / tool_use_result). Bookkeeping rows like `attachment`
//  and `output_style` don't count — Claude Code writes those for every
//  user turn even if it never produced an assistant reply.
//

import XCTest
@testable import AgentVisorCore

final class CanceledUserTurnDetectorTests: XCTestCase {
    private func row(_ uuid: String, parent: String?, type: String) -> JSONLRow {
        JSONLRow(uuid: uuid, parentUuid: parent, type: type)
    }

    // MARK: - The shape that triggered this work

    func test_userTurn_followedByOnlyAttachmentOutputStyle_isCanceled() {
        // Direct mirror of the freeze-screenshot: user → output_style →
        // attachment, no assistant. This is the exact case that should
        // hide the bubble.
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("X1", parent: "U1", type: "output_style"),
            row("X2", parent: "U1", type: "attachment"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertEqual(result, ["U1"])
    }

    func test_userTurn_withAssistantReply_isNotCanceled() {
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("A1", parent: "U1", type: "assistant"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertTrue(result.isEmpty)
    }

    func test_userTurn_withToolUseDescendant_isNotCanceled() {
        // Tool runs count as "Claude responded" — the assistant call
        // node may or may not be present in the graph, but a tool_use
        // proves the model produced output.
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("T1", parent: "U1", type: "tool_use"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertTrue(result.isEmpty)
    }

    func test_userTurn_withToolResultDescendant_isNotCanceled() {
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("R1", parent: "U1", type: "tool_result"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Multi-turn: only the canceled ones get flagged

    func test_multipleCanceledTurnsBeforeSuccessful() {
        // User cancels twice, then succeeds on the third try. All
        // three user rows share the same parentUuid (the prior turn
        // boundary) — that's the JSONL signature of cancel-and-retry
        // on the same conversation root.
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("X1", parent: "U1", type: "attachment"),
            row("U2", parent: "ROOT", type: "user"),
            row("X2", parent: "U2", type: "attachment"),
            row("U3", parent: "ROOT", type: "user"),
            row("A3", parent: "U3", type: "assistant"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertEqual(result, ["U1", "U2"])
    }

    func test_canceled_thenSuccessful_thenCanceled() {
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("U2", parent: "U1", type: "user"),
            row("A2", parent: "U2", type: "assistant"),
            row("U3", parent: "A2", type: "user"),
        ]
        // U1 canceled (only descendant is U2 chain — U2's productive
        // descendant doesn't make U1 productive on its own; but here
        // U1 IS the parent of a chain that contains assistant work,
        // so the algorithm treats U1 as productive too).
        // Reasoning: real conversation flow — if Claude eventually
        // replied somewhere downstream, the user's earlier turns in
        // the same chain are part of the context, not orphans.
        // U3 canceled: no descendants at all.
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertEqual(result, ["U3"])
    }

    // MARK: - Edge cases

    func test_emptyInput() {
        let result = CanceledUserTurnDetector.canceledUuids(rows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func test_orphanUserWithNoDescendantsAtAll_isCanceled() {
        // The "freshly canceled, no follow-ups yet" state — user
        // hits ESC, JSONL has the user row but nothing else under
        // it. Should be flagged so the bubble hides immediately.
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertEqual(result, ["U1"])
    }

    func test_assistantWithoutUserParent_isIgnored() {
        // Synthesized assistant rows without a real user turn should
        // not crash and should not be flagged.
        let rows = [
            row("A1", parent: nil, type: "assistant"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertTrue(result.isEmpty)
    }

    func test_systemRows_areNotFlagged() {
        // System / turn_duration / etc. — never user turns, never
        // candidates for "canceled."
        let rows = [
            row("S1", parent: "ROOT", type: "system"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertTrue(result.isEmpty)
    }

    func test_compactSummary_doesNotRescueCanceledUserAbove() {
        // A `compact_boundary` row appearing AFTER a canceled user
        // turn is not "Claude replied to that user." Make sure the
        // detector doesn't treat compact_boundary as productive.
        let rows = [
            row("U1", parent: "ROOT", type: "user"),
            row("X1", parent: "U1", type: "attachment"),
            row("CB", parent: "U1", type: "compact_boundary"),
        ]
        let result = CanceledUserTurnDetector.canceledUuids(rows: rows)
        XCTAssertEqual(result, ["U1"])
    }
}
