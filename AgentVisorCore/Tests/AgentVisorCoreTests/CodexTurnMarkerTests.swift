import XCTest
@testable import AgentVisorCore

final class CodexTurnMarkerTests: XCTestCase {
    private func parse(_ lines: [String]) -> CodexParsedTranscript {
        let data = Data(lines.joined(separator: "\n").utf8)
        return CodexTranscriptParser.parse(data: data)
    }

    func testLastMarkerCompletedWhenTurnEnds() {
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:50.000Z","payload":{"type":"agent_message","message":"hi"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:55.000Z","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":4000}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .completed)
    }

    func testLastMarkerStartedMidTurn() {
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":1000}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-03T21:14:00.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .started)
    }

    func testFinalAnswerMessageCompletesTurnBeforeTaskCompleteArrives() {
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
            #"{"type":"response_item","timestamp":"2026-06-03T21:13:50.000Z","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"done"}]}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .completed)
    }

    func testCommentaryMessageDoesNotCompleteTurn() {
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
            #"{"type":"response_item","timestamp":"2026-06-03T21:13:50.000Z","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"checking"}]}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .started)
    }

    func testCompletedRecordedEvenWithoutDuration() {
        // duration_ms missing → cosmetic duration block is skipped, but
        // the turn-boundary marker must still register.
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .completed)
    }

    func testNoMarkerWhenNoTurnEvents() {
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:50.000Z","payload":{"type":"agent_message","message":"hi"}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .none)
    }

    func testTurnAbortedEndsTheTurn() {
        // An interrupted turn (Esc / new prompt mid-run) emits turn_aborted
        // with no task_complete. It must register as turn-end so phase
        // inference doesn't leave the thread stuck on .processing.
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:50.000Z","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .completed)
    }

    func testTaskStartedAfterAbortIsRunningAgain() {
        // A fresh turn started after an abort is running again.
        let t = parse([
            #"{"type":"event_msg","timestamp":"2026-06-03T21:13:45.000Z","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"type":"event_msg","timestamp":"2026-06-03T21:14:00.000Z","payload":{"type":"task_started","model_context_window":272000}}"#,
        ])
        XCTAssertEqual(t.lastTurnMarker, .started)
    }
}
