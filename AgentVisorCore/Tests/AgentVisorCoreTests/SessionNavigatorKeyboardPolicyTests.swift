import XCTest
@testable import AgentVisorCore

final class SessionNavigatorKeyboardPolicyTests: XCTestCase {
    func testPhysicalArrowKeysMapToMovementOnlyWithoutModifiers() {
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 125, modifiers: []),
            .move(offset: 1)
        )
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 126, modifiers: []),
            .move(offset: -1)
        )
        XCTAssertNil(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 125, modifiers: .command)
        )
    }

    func testPhysicalActivationKeysMapStandardAndOptionReturn() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertEqual(
                SessionNavigatorKeyboardInputPolicy.event(keyCode: keyCode, modifiers: []),
                .activate(modifierIntent: .standard)
            )
            XCTAssertEqual(
                SessionNavigatorKeyboardInputPolicy.event(keyCode: keyCode, modifiers: .option),
                .activate(modifierIntent: .forceAgentVisor)
            )
        }
    }

    func testPhysicalEscapeMapsToDismissAndOtherKeysPassThrough() {
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 53, modifiers: []),
            .dismiss
        )
        XCTAssertNil(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 0, modifiers: [])
        )
        XCTAssertNil(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 53, modifiers: .shift)
        )
    }

    func testCommandFMapsToSearchFocus() {
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(keyCode: 3, modifiers: .command),
            .focusSearch
        )
    }

    func testPrintableTextAndBackspaceMapToSearchEditing() {
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(
                keyCode: 0,
                modifiers: [],
                text: "a"
            ),
            .insertText("a")
        )
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(
                keyCode: 0,
                modifiers: .shift,
                text: "A"
            ),
            .insertText("A")
        )
        XCTAssertEqual(
            SessionNavigatorKeyboardInputPolicy.event(
                keyCode: 51,
                modifiers: []
            ),
            .deleteBackward
        )
        XCTAssertNil(
            SessionNavigatorKeyboardInputPolicy.event(
                keyCode: 0,
                modifiers: .command,
                text: "a"
            )
        )
    }

    func testOpeningSelectsFirstSession() {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: nil,
            visibleSessionIDs: ["first", "second"],
            event: .opened
        )

        XCTAssertEqual(decision.cursorSessionID, "first")
        XCTAssertEqual(decision.action, .none)
    }

    func testDownMovesToNextSession() {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first", "second", "third"],
            event: .move(offset: 1)
        )

        XCTAssertEqual(decision.cursorSessionID, "second")
        XCTAssertEqual(decision.action, .none)
    }

    func testMovementStopsAtListEnds() {
        let pastLast = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "second",
            visibleSessionIDs: ["first", "second"],
            event: .move(offset: 1)
        )
        let beforeFirst = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first", "second"],
            event: .move(offset: -1)
        )

        XCTAssertEqual(pastLast.cursorSessionID, "second")
        XCTAssertEqual(beforeFirst.cursorSessionID, "first")
    }

    func testReturnOpensSelectedSessionInOriginalOwner() {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "second",
            visibleSessionIDs: ["first", "second"],
            event: .activate(modifierIntent: .standard)
        )

        XCTAssertEqual(decision.cursorSessionID, "second")
        XCTAssertEqual(
            decision.action,
            .open(sessionID: "second", modifierIntent: .standard)
        )
    }

    func testEscapeDismissesWithoutChangingSelection() {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "second",
            visibleSessionIDs: ["first", "second"],
            event: .dismiss
        )

        XCTAssertEqual(decision.cursorSessionID, "second")
        XCTAssertEqual(decision.action, .dismiss)
    }

    func testEscapeClearsSearchBeforeDismissingThePopover() {
        let clearDecision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "second",
            visibleSessionIDs: ["first", "second"],
            query: "codex",
            event: .dismiss
        )
        let dismissDecision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first", "second"],
            query: "",
            event: .dismiss
        )

        XCTAssertEqual(clearDecision.query, "")
        XCTAssertEqual(clearDecision.action, .none)
        XCTAssertEqual(dismissDecision.action, .dismiss)
    }

    func testTypingAndBackspaceEditTheSearchQuery() {
        let typedDecision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first"],
            query: "code",
            event: .insertText("x")
        )
        let deletedDecision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first"],
            query: typedDecision.query,
            event: .deleteBackward
        )

        XCTAssertEqual(typedDecision.query, "codex")
        XCTAssertEqual(typedDecision.action, .none)
        XCTAssertEqual(deletedDecision.query, "code")
        XCTAssertEqual(deletedDecision.action, .none)
    }

    func testOptionReturnOpensSelectedSessionInAgentVisor() {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: "first",
            visibleSessionIDs: ["first", "second"],
            event: .activate(modifierIntent: .forceAgentVisor)
        )

        XCTAssertEqual(
            decision.action,
            .open(sessionID: "first", modifierIntent: .forceAgentVisor)
        )
    }
}
