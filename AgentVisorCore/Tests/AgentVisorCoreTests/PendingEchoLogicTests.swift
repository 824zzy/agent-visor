//
//  PendingEchoLogicTests.swift
//  AgentVisorCoreTests
//
//  Tests the pure dictionary-mutation logic that PendingEchoStore (in
//  the main app target) delegates to. The store itself owns
//  @Published state + Combine; this Core type owns the WHAT-changes
//  decisions so they can be unit-tested without mocking SwiftUI.
//

import XCTest
@testable import AgentVisorCore

final class PendingEchoLogicTests: XCTestCase {
    // MARK: - push

    func test_push_appendsToSession() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "hello")
        XCTAssertEqual(state["S1"]?.count, 1)
        XCTAssertEqual(state["S1"]?.first?.id, "echo:1")
        XCTAssertEqual(state["S1"]?.first?.text, "hello")
    }

    func test_push_preservesExistingItems() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "first")]
        ]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:2", text: "second")
        XCTAssertEqual(state["S1"]?.count, 2)
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:1", "echo:2"])
    }

    func test_push_emptyText_isNoOp() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "")
        XCTAssertNil(state["S1"])
    }

    func test_push_whitespaceOnlyText_isNoOp() {
        var state: [String: [PendingEchoItem]] = [:]
        state = PendingEchoLogic.push(into: state, sessionId: "S1", id: "echo:1", text: "   \n\t")
        XCTAssertNil(state["S1"])
    }

    // MARK: - evictAll (THE NEW BEHAVIOR ESC-CANCEL TRIGGERS)

    func test_evictAll_clearsTargetSession() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "first"),
                PendingEchoItem(id: "echo:2", text: "second"),
            ]
        ]
        state = PendingEchoLogic.evictAll(from: state, sessionId: "S1")
        XCTAssertNil(state["S1"], "evictAll should remove the session entry entirely")
    }

    func test_evictAll_doesNotTouchOtherSessions() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "for S1")],
            "S2": [PendingEchoItem(id: "echo:2", text: "for S2")],
        ]
        state = PendingEchoLogic.evictAll(from: state, sessionId: "S1")
        XCTAssertNil(state["S1"])
        XCTAssertEqual(state["S2"]?.count, 1)
        XCTAssertEqual(state["S2"]?.first?.text, "for S2")
    }

    func test_evictAll_unknownSession_isNoOp() {
        let initial: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "first")]
        ]
        let result = PendingEchoLogic.evictAll(from: initial, sessionId: "S-other")
        XCTAssertEqual(result["S1"]?.count, 1)
    }

    // MARK: - evictById

    func test_evictById_removesOneAndKeepsRest() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "first"),
                PendingEchoItem(id: "echo:2", text: "second"),
            ]
        ]
        state = PendingEchoLogic.evict(from: state, sessionId: "S1", id: "echo:1")
        XCTAssertEqual(state["S1"]?.map(\.id), ["echo:2"])
    }

    func test_evictById_lastItem_removesEntireSessionEntry() {
        var state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "only")]
        ]
        state = PendingEchoLogic.evict(from: state, sessionId: "S1", id: "echo:1")
        XCTAssertNil(state["S1"])
    }

    // MARK: - reconcile (text-match against real JSONL turns)

    func test_reconcile_removesEchoMatchedByText() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello world")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["hello world"]
        )
        XCTAssertNil(result["S1"], "matched echo should evict; empty list collapses to nil entry")
    }

    func test_reconcile_keepsEchoNotInRealTexts() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [
                PendingEchoItem(id: "echo:1", text: "still pending"),
                PendingEchoItem(id: "echo:2", text: "already landed"),
            ]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["already landed"]
        )
        XCTAssertEqual(result["S1"]?.count, 1)
        XCTAssertEqual(result["S1"]?.first?.id, "echo:1")
    }

    func test_reconcile_trimsWhitespaceOnBothSides() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "  hello  ")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["hello"]
        )
        XCTAssertNil(result["S1"], "trimmed text comparison should match")
    }

    // MARK: - reconcile: image-paste prefix tolerance
    //
    // Claude Code's TUI rewrites the user turn in JSONL as
    // "[Image #N] <typed text>" when images are attached. The optimistic
    // echo carries only the typed text, so strict equality misses the
    // match. Reconcile should strip leading [Image]/[Image #N] tokens
    // from both sides before comparing.

    func test_reconcile_realTextWithImageNumberPrefix_matchesPlainEcho() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "No, you misunderstood")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #61] No, you misunderstood"]
        )
        XCTAssertNil(result["S1"], "[Image #N] prefix on real text should not block reconcile")
    }

    func test_reconcile_multipleImagePrefixes_matchPlainEcho() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "compare these")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1] [Image #2] compare these"]
        )
        XCTAssertNil(result["S1"])
    }

    func test_reconcile_echoWithPlainImagePrefix_matchesNumberedReal() {
        // Notch path's optimistic echo decorates with [Image] (no number).
        // Be tolerant on both sides.
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "[Image] hello")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #5] hello"]
        )
        XCTAssertNil(result["S1"])
    }

    func test_reconcile_imagePrefixOnUnrelatedText_doesNotFalseMatch() {
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello world")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1] something else entirely"]
        )
        XCTAssertEqual(result["S1"]?.count, 1, "different post-prefix text must not match")
    }

    func test_reconcile_midStringImageMention_isNotStripped() {
        // Only LEADING [Image #N] tokens are placeholder injections.
        // Mid-string mentions are real content; matching stays exact.
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "see [Image #1]?")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["see [Image #1]?"]
        )
        XCTAssertNil(result["S1"], "exact-string mid-mention still matches")
    }

    func test_reconcile_imagePrefixOnly_doesNotEvictPlainEcho() {
        // Image-only sends never produce an echo (push trims to empty),
        // but be defensive — a real text that's purely "[Image #1]" must
        // not match an echo of "hello".
        let state: [String: [PendingEchoItem]] = [
            "S1": [PendingEchoItem(id: "echo:1", text: "hello")]
        ]
        let result = PendingEchoLogic.reconcile(
            state,
            sessionId: "S1",
            realUserTexts: ["[Image #1]"]
        )
        XCTAssertEqual(result["S1"]?.count, 1)
    }
}
