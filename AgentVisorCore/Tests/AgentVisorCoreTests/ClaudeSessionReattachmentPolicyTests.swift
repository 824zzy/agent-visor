import XCTest
@testable import AgentVisorCore

final class ClaudeSessionReattachmentPolicyTests: XCTestCase {
    func testLiveReusedPidThatDoesNotBelongToClaudeIsRejected() {
        let attachment = ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: 100,
            candidate: ClaudeSessionReattachmentCandidate(
                pid: 200,
                matchedSessionId: "session-1",
                processCommand: "/usr/bin/sleep 999",
                isAlive: true,
                tty: "ttys009",
                terminalHost: .iterm2,
                metadataStatus: nil,
                sessionName: "Project",
                isInTmux: false
            )
        )

        XCTAssertNil(attachment)
    }

    func testValidTerminalAttachmentRestoresCompleteMetadataAsIdle() {
        let attachment = ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: 100,
            candidate: ClaudeSessionReattachmentCandidate(
                pid: 200,
                matchedSessionId: "session-1",
                processCommand: "/Users/me/.local/bin/claude --resume session-1",
                isAlive: true,
                tty: "ttys009",
                terminalHost: .iterm2,
                metadataStatus: "idle",
                sessionName: "Project",
                isInTmux: true
            )
        )

        XCTAssertEqual(
            attachment,
            ClaudeSessionReattachment(
                pid: 200,
                tty: "ttys009",
                terminalHost: .iterm2,
                origin: .terminal,
                sessionName: "Project",
                isInTmux: true,
                phase: .idle
            )
        )
    }

    func testCursorHostedAttachmentRefreshesOriginWithoutPretendingItHasATerminal() {
        let attachment = ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: nil,
            candidate: ClaudeSessionReattachmentCandidate(
                pid: 200,
                matchedSessionId: "session-1",
                processCommand: "/Applications/Cursor.app/claude.app/Contents/MacOS/claude",
                isAlive: true,
                tty: nil,
                terminalHost: .cursor,
                metadataStatus: nil,
                sessionName: nil,
                isInTmux: false
            )
        )

        XCTAssertEqual(attachment?.origin, .cursorObserved)
        XCTAssertEqual(attachment?.phase, .idle)
    }

    func testMismatchedSessionTerminalStatusAndExcludedPidAreRejected() {
        let base = ClaudeSessionReattachmentCandidate(
            pid: 200,
            matchedSessionId: "other-session",
            processCommand: "claude --resume session-1",
            isAlive: true,
            tty: "ttys009",
            terminalHost: .iterm2,
            metadataStatus: nil,
            sessionName: nil,
            isInTmux: false
        )
        XCTAssertNil(ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: nil,
            candidate: base
        ))

        let ended = ClaudeSessionReattachmentCandidate(
            pid: 200,
            matchedSessionId: "session-1",
            processCommand: "claude --resume session-1",
            isAlive: true,
            tty: "ttys009",
            terminalHost: .iterm2,
            metadataStatus: "ended",
            sessionName: nil,
            isInTmux: false
        )
        XCTAssertNil(ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: nil,
            candidate: ended
        ))
        let active = ClaudeSessionReattachmentCandidate(
            pid: 200,
            matchedSessionId: "session-1",
            processCommand: "claude --resume session-1",
            isAlive: true,
            tty: "ttys009",
            terminalHost: .iterm2,
            metadataStatus: "idle",
            sessionName: nil,
            isInTmux: false
        )
        XCTAssertNil(ClaudeSessionReattachmentPolicy.attachment(
            requestedSessionId: "session-1",
            excludedPid: 200,
            candidate: active
        ))
    }
}
