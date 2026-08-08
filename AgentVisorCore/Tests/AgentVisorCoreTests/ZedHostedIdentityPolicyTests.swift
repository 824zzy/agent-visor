import XCTest
@testable import AgentVisorCore

final class ZedThreadRecordTests: XCTestCase {
    private func record(
        title: String? = nil,
        titleOverride: String? = nil,
        agentIdentifier: String? = "claude-acp",
        sessionID: String? = "7752fd3d-251a-4f16-ad06-d6b6182aebd5",
        worktreePaths: [String] = ["/Users/dev/Codes"],
        updatedAt: Date? = nil,
        interactedAt: Date? = nil
    ) -> ZedThreadRecord {
        ZedThreadRecord(
            threadID: "294C3A1ADCF642D7A5902AE6612ED545",
            sessionID: sessionID,
            agentIdentifier: agentIdentifier,
            title: title,
            titleOverride: titleOverride,
            worktreePaths: worktreePaths,
            archived: false,
            updatedAt: updatedAt,
            interactedAt: interactedAt
        )
    }

    func testUserRenameWinsOverGeneratedTitle() {
        XCTAssertEqual(
            record(title: "hi", titleOverride: "IBM gap analysis").displayTitle,
            "IBM gap analysis"
        )
    }

    func testGeneratedTitleUsedWhenNoOverride() {
        XCTAssertEqual(record(title: "hi").displayTitle, "hi")
    }

    func testEmptyAndWhitespaceTitlesAreNotTitles() {
        // pi-acp rows land with `title: ""` until Zed summarizes; the pill
        // must fall back rather than render blank.
        XCTAssertNil(record(title: "").displayTitle)
        XCTAssertNil(record(title: "   ", titleOverride: "\n").displayTitle)
        XCTAssertNil(record().displayTitle)
    }

    func testAgentIdentifierMapping() {
        XCTAssertEqual(ZedThreadRecord.agentID(forZedAgentIdentifier: "claude-acp"), .claudeCode)
        XCTAssertEqual(ZedThreadRecord.agentID(forZedAgentIdentifier: "codex-acp"), .codex)
        XCTAssertEqual(ZedThreadRecord.agentID(forZedAgentIdentifier: "pi-acp"), .pi)
        XCTAssertEqual(ZedThreadRecord.agentID(forZedAgentIdentifier: "cursor"), .cursor)
        XCTAssertEqual(ZedThreadRecord.agentID(forZedAgentIdentifier: "CLAUDE-ACP"), .claudeCode)
    }

    func testZedNativeAgentHasNoTranscriptOwner() {
        XCTAssertNil(ZedThreadRecord.agentID(forZedAgentIdentifier: "zed"))
        XCTAssertNil(ZedThreadRecord.agentID(forZedAgentIdentifier: "gemini"))
        XCTAssertNil(ZedThreadRecord.agentID(forZedAgentIdentifier: nil))
    }

    func testWorktreePathParsing() {
        XCTAssertEqual(
            ZedThreadRecord.worktreePaths(from: "/Users/dev/Codes"),
            ["/Users/dev/Codes"]
        )
        XCTAssertEqual(
            ZedThreadRecord.worktreePaths(from: "/a\n/b\n"),
            ["/a", "/b"]
        )
        XCTAssertEqual(ZedThreadRecord.worktreePaths(from: ""), [])
        XCTAssertEqual(ZedThreadRecord.worktreePaths(from: nil), [])
    }

    func testLastTouchedAtPrefersNewerStamp() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(record(updatedAt: newer, interactedAt: older).lastTouchedAt, newer)
        XCTAssertEqual(record(updatedAt: older, interactedAt: newer).lastTouchedAt, newer)
        XCTAssertEqual(record(interactedAt: newer).lastTouchedAt, newer)
        XCTAssertNil(record().lastTouchedAt)
    }
}

final class ZedHostedIdentityPolicyTests: XCTestCase {
    func testZedHostSuppressesAgentDerivedNames() {
        // Regression: a Zed thread titled "hi" rendered as `codes-92`,
        // claude-code's derived `<pid>.json` name.
        XCTAssertTrue(ZedHostedIdentityPolicy.suppressesAgentResolvedName(host: .zed))
        XCTAssertFalse(ZedHostedIdentityPolicy.suppressesAgentResolvedName(host: .ghostty))
        XCTAssertFalse(ZedHostedIdentityPolicy.suppressesAgentResolvedName(host: .codexApp))
        XCTAssertFalse(ZedHostedIdentityPolicy.suppressesAgentResolvedName(host: nil))
    }

    func testZedTitleWins() {
        XCTAssertEqual(
            ZedHostedIdentityPolicy.sessionName(
                zedTitle: "pi-test-2",
                currentName: "codes-92",
                transcriptTitle: "transcript name"
            ),
            "pi-test-2"
        )
    }

    func testFallsBackToCurrentThenTranscript() {
        XCTAssertEqual(
            ZedHostedIdentityPolicy.sessionName(
                zedTitle: nil,
                currentName: "kept name",
                transcriptTitle: "transcript name"
            ),
            "kept name"
        )
        XCTAssertEqual(
            ZedHostedIdentityPolicy.sessionName(
                zedTitle: "  ",
                currentName: "",
                transcriptTitle: "transcript name"
            ),
            "transcript name"
        )
        XCTAssertNil(
            ZedHostedIdentityPolicy.sessionName(zedTitle: nil, currentName: nil)
        )
    }

    func testShouldApplyOnlyOnRealChange() {
        XCTAssertTrue(ZedHostedIdentityPolicy.shouldApply(resolved: "hi", currentName: "codes-92"))
        XCTAssertFalse(ZedHostedIdentityPolicy.shouldApply(resolved: "hi", currentName: "hi"))
        XCTAssertFalse(ZedHostedIdentityPolicy.shouldApply(resolved: "  ", currentName: "hi"))
        XCTAssertFalse(ZedHostedIdentityPolicy.shouldApply(resolved: nil, currentName: "hi"))
    }
}

final class HostedAgentHostPolicyTests: XCTestCase {
    func testProcessTreeEvidenceBeatsCodexNoTtyFallback() {
        // Regression: codex-acp inside Zed has no tty, so the old
        // short-circuit labeled it Codex.app and navigation opened the
        // wrong application.
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .codex, tty: nil, detectedHost: .zed),
            .zed
        )
    }

    func testCodexGuiThreadStillFallsBackToCodexApp() {
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .codex, tty: nil, detectedHost: nil),
            .codexApp
        )
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .codex, tty: nil, detectedHost: .unknown),
            .codexApp
        )
    }

    func testCodexCliKeepsItsTerminalHost() {
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .codex, tty: "ttys004", detectedHost: .ghostty),
            .ghostty
        )
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .codex, tty: "ttys004", detectedHost: .unknown),
            .unknown
        )
    }

    func testOtherAgentsAreUnaffected() {
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(agentID: .pi, tty: nil, detectedHost: .zed),
            .zed
        )
        XCTAssertNil(
            HostedAgentHostPolicy.resolve(agentID: .claudeCode, tty: nil, detectedHost: nil)
        )
    }

    func testZedThreadListOverridesCodexAppFallback() {
        // Regression: a codex-acp thread inside Zed also leaves a `~/.codex`
        // rollout, so the codex provider claimed it (no tty, no live pid →
        // Codex.app) and the pill click opened Codex Desktop. Zed's own
        // thread list is authoritative and must force `.zed`.
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(
                agentID: .codex,
                tty: nil,
                detectedHost: nil,
                zedHostsSession: true
            ),
            .zed
        )
    }

    func testZedThreadListOverridesEvenADetectedTerminalHost() {
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(
                agentID: .claudeCode,
                tty: "ttys003",
                detectedHost: .ghostty,
                zedHostsSession: true
            ),
            .zed
        )
    }

    func testNoZedOverrideKeepsExistingBehavior() {
        XCTAssertEqual(
            HostedAgentHostPolicy.resolve(
                agentID: .codex,
                tty: nil,
                detectedHost: nil,
                zedHostsSession: false
            ),
            .codexApp
        )
    }
}
