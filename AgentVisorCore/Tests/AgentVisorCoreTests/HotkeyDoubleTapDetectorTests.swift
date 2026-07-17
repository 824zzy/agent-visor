import XCTest
@testable import AgentVisorCore

/// Double-tap-modifier detector used by agent-visor's global hotkey.
/// Models the gesture as a state machine: down→up→down→up of the
/// configured trigger modifier alone, each release within
/// `cleanTapMaxDuration`, second tap starting within `doubleTapWindow`
/// of the first release, with no foreign modifier and no non-modifier
/// key in between. Fires on the SECOND release, not the second down,
/// so chords like shift-then-`9` (for `(`) abort cleanly.
final class HotkeyDoubleTapDetectorTests: XCTestCase {

    /// Tighter than production so window-boundary tests stay readable.
    private static let cfg = HotkeyDoubleTapConfig(
        doubleTapWindow: 0.2,
        cleanTapMaxDuration: 0.14
    )

    private static func at(_ ms: Int) -> Date {
        // Anchor everything to a fixed epoch so tests are timestamp-stable.
        Date(timeIntervalSince1970: 1_000_000_000).addingTimeInterval(TimeInterval(ms) / 1000.0)
    }

    // MARK: - Scenario 1: empty input

    func test_givenNoEvents_thenDetectorNeverFires() {
        // Given a fresh detector
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        // When nothing is fed
        // Then no fire signal is produced (trivially — no calls made)
        // Sanity: an idle stray triggerUp shouldn't fire either.
        XCTAssertEqual(detector.handle(.triggerUp(at: Self.at(0))), .noChange)
    }

    // MARK: - Scenario 2: only a single tap

    func test_givenSingleTap_thenNoFire() {
        // Given one clean tap (down then up well within cleanTapMaxDuration)
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        // When tap fires
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        let out = detector.handle(.triggerUp(at: Self.at(50)))
        // Then no fire — second tap never came
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 3: happy path, two clean taps in window

    func test_givenTwoCleanTapsWithinWindow_thenFiresOnSecondRelease() {
        // Given two clean taps with the second starting 100ms after first release
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        // When the gesture completes
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))     // first tap: 50ms hold
        _ = detector.handle(.triggerDown(at: Self.at(150)))  // 100ms < 200ms window
        let out = detector.handle(.triggerUp(at: Self.at(200))) // second tap: 50ms hold
        // Then the second release fires
        XCTAssertEqual(out, .fired)
    }

    // MARK: - Scenario 4: second tap fires on release, not on down

    func test_givenSecondTapDown_thenNoFireUntilRelease() {
        // Given the user has completed the first tap and pressed the second
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        // When the second tap goes DOWN but has not yet released
        let outOnDown = detector.handle(.triggerDown(at: Self.at(150)))
        // Then no fire yet — fire-on-release is what kills shift-shift-then-chord misfires
        XCTAssertEqual(outOnDown, .noChange)
        // Releasing cleanly completes the fire
        let outOnUp = detector.handle(.triggerUp(at: Self.at(200)))
        XCTAssertEqual(outOnUp, .fired)
    }

    // MARK: - Scenario 5: second tap starts after window expires

    func test_givenSecondTapAfterWindowExpires_thenNoFire_andReArmsAsFirst() {
        // Given the user is slow — second tap starts 300ms after first release
        // (200ms window has expired)
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(350)))  // 300ms > 200ms
        let out = detector.handle(.triggerUp(at: Self.at(400)))
        // Then no fire — the late press becomes a fresh first tap
        XCTAssertEqual(out, .noChange)
        // And another tap within the new window from this fresh first DOES fire
        _ = detector.handle(.triggerDown(at: Self.at(500)))
        let outFollowUp = detector.handle(.triggerUp(at: Self.at(550)))
        XCTAssertEqual(outFollowUp, .fired)
    }

    // MARK: - Scenario 6: first tap held too long

    func test_givenFirstTapHeldTooLong_thenSubsequentTapDoesNotComplete() {
        // Given the user is holding shift (e.g. to capitalize), not tapping it
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(200)))  // 200ms > 140ms — that's a hold, not a tap
        // When the user later does a real second tap
        _ = detector.handle(.triggerDown(at: Self.at(250)))
        let out = detector.handle(.triggerUp(at: Self.at(290)))
        // Then no fire — the held first tap was dropped, so this "second" is treated as a fresh first
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 7: second tap held too long

    func test_givenSecondTapHeldTooLong_thenNoFire() {
        // Given the user starts a clean first tap and then holds the second
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(150)))
        // When the second tap is held over the limit
        let out = detector.handle(.triggerUp(at: Self.at(310))) // 160ms hold > 140ms
        // Then no fire
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 8: non-modifier key between taps aborts

    func test_givenNonModifierKeyDownBetweenTaps_thenSecondTapDoesNotFire() {
        // Given the user types a letter between the two taps
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.nonModifierKeyDown(at: Self.at(100)))
        // When the second tap then completes
        _ = detector.handle(.triggerDown(at: Self.at(150)))
        let out = detector.handle(.triggerUp(at: Self.at(190)))
        // Then no fire — typing-during-gesture is not the gesture
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 9: non-modifier key during the second tap aborts

    func test_givenNonModifierKeyDownDuringSecondTap_thenAborts() {
        // Given the user begins shift-shift but then types `9` for `(`
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(150)))     // second tap starts
        _ = detector.handle(.nonModifierKeyDown(at: Self.at(170))) // `9` keydown
        // When the user then releases shift
        let out = detector.handle(.triggerUp(at: Self.at(200)))
        // Then no fire — chord, not double-tap. This is the primary
        // false-positive killer that fire-on-release enables.
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 10: foreign modifier during the gesture aborts

    func test_givenForeignModifierHeld_thenAborts() {
        // Given a first tap then a chord starting (cmd added)
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(120)))
        _ = detector.handle(.foreignModifierHeld(at: Self.at(140)))  // cmd joined
        // When the release later arrives
        let out = detector.handle(.triggerUp(at: Self.at(180)))
        // Then no fire — chord, not a clean double-tap
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 11: second-tap window boundary

    func test_givenSecondTapStartsAtExactWindowBoundary_thenFires() {
        // Given the second tap starts EXACTLY at window edge (200ms)
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(250)))  // exactly 200ms after first up
        let out = detector.handle(.triggerUp(at: Self.at(300)))
        // Then it still fires — boundary is inclusive
        XCTAssertEqual(out, .fired)
    }

    func test_givenSecondTapStartsJustOutsideWindow_thenDoesNotFire() {
        // Given second tap starts 1ms past the window
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(251)))  // 201ms after first up
        let out = detector.handle(.triggerUp(at: Self.at(290)))
        // Then no fire (the new press re-arms as a fresh first tap)
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 12: tap-hold boundary

    func test_givenTapHoldJustUnderMaxDuration_thenStillCounts() {
        // Given both taps hit just under the 140ms ceiling. Avoiding
        // exact-boundary timestamps because `Date` arithmetic loses
        // bits in the (large − large = small) subtraction, and real
        // users can't tap at 140.000000ms anyway.
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(139)))
        _ = detector.handle(.triggerDown(at: Self.at(200)))
        let out = detector.handle(.triggerUp(at: Self.at(339)))
        // Then fires — comfortably inside the boundary
        XCTAssertEqual(out, .fired)
    }

    func test_givenTapHoldJustOverMaxDuration_thenDoesNotCount() {
        // Given the second tap is held 141ms
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(150)))
        let out = detector.handle(.triggerUp(at: Self.at(291)))  // 141ms hold
        // Then no fire
        XCTAssertEqual(out, .noChange)
    }

    // MARK: - Scenario 13: state resets after a successful fire

    func test_givenSuccessfulFireThenAnotherGesture_thenFiresAgain() {
        // Given a first complete double-tap that fires
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(150)))
        XCTAssertEqual(detector.handle(.triggerUp(at: Self.at(200))), .fired)
        // When the user does another double-tap a second later
        _ = detector.handle(.triggerDown(at: Self.at(1000)))
        _ = detector.handle(.triggerUp(at: Self.at(1050)))
        _ = detector.handle(.triggerDown(at: Self.at(1150)))
        let out = detector.handle(.triggerUp(at: Self.at(1200)))
        // Then it fires again — internal state reset after the prior fire
        XCTAssertEqual(out, .fired)
    }

    // MARK: - Scenario 14: repeated trigger-down without intervening up re-arms

    func test_givenRepeatedTriggerDownWithoutRelease_thenReArmsAsFirstTap() {
        // Given a clean first tap, then second-down, then ANOTHER second-down
        // without an intervening up (defensive — shouldn't happen from AppKit
        // but the state machine should be robust)
        let detector = HotkeyDoubleTapDetector(config: Self.cfg)
        _ = detector.handle(.triggerDown(at: Self.at(0)))
        _ = detector.handle(.triggerUp(at: Self.at(50)))
        _ = detector.handle(.triggerDown(at: Self.at(150)))
        _ = detector.handle(.triggerDown(at: Self.at(160)))  // second down without prior up
        // When this latest "first" tap finishes cleanly and a real second follows
        _ = detector.handle(.triggerUp(at: Self.at(200)))
        _ = detector.handle(.triggerDown(at: Self.at(280)))
        let out = detector.handle(.triggerUp(at: Self.at(320)))
        // Then the latest gesture fires; the desync didn't latch into a permanent bad state
        XCTAssertEqual(out, .fired)
    }
}
