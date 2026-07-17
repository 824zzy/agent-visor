//
//  ChatTailAutoPinPolicyTests.swift
//  AgentVisorCoreTests
//

import XCTest
@testable import AgentVisorCore

final class ChatTailAutoPinPolicyTests: XCTestCase {
    // The policy answers two related questions:
    //
    //   1. Should we auto-scroll to the new bottom when a row is
    //      inserted at the tail?  → `shouldAutoPinOnInsert`
    //   2. Is the user "near the bottom" right now? — used by the
    //      view layer to enable the streaming-tick scroll. → `isNearBottom`
    //
    // The threshold mirrors the Slack/iMessage behavior: stay pinned
    // unless the user has scrolled "noticeably up" from the bottom,
    // typically more than a viewport's worth.

    // MARK: - isNearBottom

    func testIsNearBottomTrueAtBottom() {
        // distanceFromBottom == 0 → at-bottom
        XCTAssertTrue(ChatTailAutoPinPolicy.isNearBottom(
            distanceFromBottom: 0,
            threshold: 80
        ))
    }

    func testIsNearBottomTrueWithinThreshold() {
        XCTAssertTrue(ChatTailAutoPinPolicy.isNearBottom(
            distanceFromBottom: 50,
            threshold: 80
        ))
    }

    func testIsNearBottomTrueAtThresholdBoundary() {
        XCTAssertTrue(ChatTailAutoPinPolicy.isNearBottom(
            distanceFromBottom: 80,
            threshold: 80
        ))
    }

    func testIsNearBottomFalsePastThreshold() {
        XCTAssertFalse(ChatTailAutoPinPolicy.isNearBottom(
            distanceFromBottom: 81,
            threshold: 80
        ))
    }

    func testIsNearBottomFalseFarUp() {
        XCTAssertFalse(ChatTailAutoPinPolicy.isNearBottom(
            distanceFromBottom: 1500,
            threshold: 80
        ))
    }

    // MARK: - shouldAutoPinOnInsert

    func testInsertWhileAtBottomPins() {
        XCTAssertTrue(ChatTailAutoPinPolicy.shouldAutoPinOnInsert(
            distanceFromBottom: 0,
            threshold: 80,
            insertedAtTail: true
        ))
    }

    func testInsertWhileScrolledUpDoesNotPin() {
        XCTAssertFalse(ChatTailAutoPinPolicy.shouldAutoPinOnInsert(
            distanceFromBottom: 1000,
            threshold: 80,
            insertedAtTail: true
        ))
    }

    func testInsertNotAtTailNeverPins() {
        // load-earlier inserts at head; we must NOT auto-scroll
        // because the user just asked for older history.
        XCTAssertFalse(ChatTailAutoPinPolicy.shouldAutoPinOnInsert(
            distanceFromBottom: 0,
            threshold: 80,
            insertedAtTail: false
        ))
    }

    // MARK: - shouldStreamPin

    func testStreamPinFollowsNearBottom() {
        // Streaming-tick scroll is the same predicate as isNearBottom:
        // text is growing inside the last row; if the user is at-bottom
        // we keep them at-bottom.
        XCTAssertTrue(ChatTailAutoPinPolicy.shouldStreamPin(
            distanceFromBottom: 10,
            threshold: 80
        ))
        XCTAssertFalse(ChatTailAutoPinPolicy.shouldStreamPin(
            distanceFromBottom: 200,
            threshold: 80
        ))
    }

    // MARK: - default threshold sanity

    func testDefaultThresholdIsReasonable() {
        // The default should be "about a viewport line" — large enough
        // to forgive momentum-scroll overshoot but small enough that
        // users feel the pin "release" when they actively scroll up.
        XCTAssertGreaterThan(ChatTailAutoPinPolicy.defaultNearBottomThreshold, 20)
        XCTAssertLessThan(ChatTailAutoPinPolicy.defaultNearBottomThreshold, 400)
    }
}
