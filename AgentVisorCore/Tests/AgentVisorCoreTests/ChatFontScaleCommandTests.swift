import XCTest
@testable import AgentVisorCore

final class ChatFontScaleCommandTests: XCTestCase {
    // MARK: - decode

    func testDecodeIgnoresEventsWithoutCommandModifier() {
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: false, charactersIgnoringModifiers: "="))
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: false, charactersIgnoringModifiers: "-"))
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: false, charactersIgnoringModifiers: "0"))
    }

    func testDecodeRecognizesEqualsAsZoomIn() {
        XCTAssertEqual(
            ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "="),
            .zoomIn
        )
    }

    func testDecodeRecognizesPlusAsZoomIn() {
        // Shift+= produces "+", which we should treat as zoom-in too.
        XCTAssertEqual(
            ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "+"),
            .zoomIn
        )
    }

    func testDecodeRecognizesMinusAsZoomOut() {
        XCTAssertEqual(
            ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "-"),
            .zoomOut
        )
        // Shift+- (underscore) — accept as zoom out for symmetry with
        // the +/= shift-tolerance.
        XCTAssertEqual(
            ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "_"),
            .zoomOut
        )
    }

    func testDecodeRecognizesZeroAsReset() {
        XCTAssertEqual(
            ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "0"),
            .reset
        )
    }

    func testDecodeReturnsNilForOtherCmdKeystrokes() {
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "a"))
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: ""))
        XCTAssertNil(ChatFontScaleCommand.decode(commandHeld: true, charactersIgnoringModifiers: "1"))
    }

    // MARK: - apply

    func testZoomInIncrementsByStep() {
        let next = ChatFontScaleCommand.zoomIn.apply(to: 1.0, step: 0.1, min: 0.8, max: 2.5)
        XCTAssertEqual(next, 1.1, accuracy: 1e-6)
    }

    func testZoomOutDecrementsByStep() {
        let next = ChatFontScaleCommand.zoomOut.apply(to: 1.0, step: 0.1, min: 0.8, max: 2.5)
        XCTAssertEqual(next, 0.9, accuracy: 1e-6)
    }

    func testResetReturnsOne() {
        XCTAssertEqual(
            ChatFontScaleCommand.reset.apply(to: 2.0, step: 0.1, min: 0.8, max: 2.5),
            1.0,
            accuracy: 1e-6
        )
    }

    func testZoomInClampsAtMax() {
        let next = ChatFontScaleCommand.zoomIn.apply(to: 2.5, step: 0.1, min: 0.8, max: 2.5)
        XCTAssertEqual(next, 2.5, accuracy: 1e-6)
    }

    func testZoomOutClampsAtMin() {
        let next = ChatFontScaleCommand.zoomOut.apply(to: 0.8, step: 0.1, min: 0.8, max: 2.5)
        XCTAssertEqual(next, 0.8, accuracy: 1e-6)
    }

    func testRoundingPreventsFloatDrift() {
        // Three zoom-ins from 1.0 with step 0.1 should land exactly
        // at 1.3, not 1.30000000000000004.
        var v = 1.0
        for _ in 0..<3 {
            v = ChatFontScaleCommand.zoomIn.apply(to: v, step: 0.1, min: 0.8, max: 2.5)
        }
        XCTAssertEqual(v, 1.3)
    }
}
