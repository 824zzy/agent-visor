import XCTest
@testable import AgentVisorCore

/// Behaviour of the session model itself.
///
/// The model moved into this package so that rules could take a session. That move also made
/// these properties testable for the first time. Before it, three audits checked them by reading
/// `SessionState.swift` as text, which can only prove that a line exists somewhere in the file.
final class SessionStateBehaviourTests: XCTestCase {
    // MARK: - Model name

    func testDisplayModelNamePrefersTheCatalogName() {
        let session = SessionStateFixture.make(
            modelName: "claude-sonnet-4-5-20250929",
            modelDisplayName: "Claude Sonnet 4.5"
        )
        XCTAssertEqual(session.displayModelName, "Claude Sonnet 4.5")
    }

    func testDisplayModelNameFallsBackToTheRawIdentifier() {
        let session = SessionStateFixture.make(modelName: "some-unknown-model-2030")
        XCTAssertNotNil(
            session.displayModelName,
            "An unknown model still needs a name on screen, so the raw id is the fallback."
        )
    }

    func testDisplayModelNameIsNilWithoutAModel() {
        XCTAssertNil(SessionStateFixture.make().displayModelName)
    }

    func testApplyModelMetadataIgnoresPlaceholderIdentifiers() {
        var session = SessionStateFixture.make(modelName: "claude-opus-4")
        session.applyModelMetadata(modelID: "<synthetic>", catalogDisplayName: "Nonsense")
        XCTAssertEqual(session.modelName, "claude-opus-4", "A placeholder id must not overwrite a real one.")

        session.applyModelMetadata(modelID: "", catalogDisplayName: "Nonsense")
        XCTAssertEqual(session.modelName, "claude-opus-4", "An empty id must not overwrite a real one.")
    }

    func testApplyModelMetadataStoresARealIdentifier() {
        var session = SessionStateFixture.make()
        session.applyModelMetadata(modelID: "claude-haiku-4-5", catalogDisplayName: "Claude Haiku 4.5")
        XCTAssertEqual(session.modelName, "claude-haiku-4-5")
        XCTAssertEqual(session.displayModelName, "Claude Haiku 4.5")
    }

    func testANewModelClearsTheOldCatalogName() {
        var session = SessionStateFixture.make(
            modelName: "claude-sonnet-4-5",
            modelDisplayName: "Claude Sonnet 4.5"
        )
        session.applyModelMetadata(modelID: "claude-opus-4-8", catalogDisplayName: nil)
        XCTAssertNil(
            session.modelDisplayName,
            "A new model must not wear the previous model's name."
        )
        XCTAssertEqual(session.modelName, "claude-opus-4-8")
    }

    // MARK: - Permission mode

    func testPermissionModeSurfaceStaysHiddenForNonClaudeProviders() {
        for agent in [AgentID.pi, .codex, .cursor, .auggie] {
            var session = SessionStateFixture.make(agentID: agent, tty: "ttys004")
            session.permissionMode = "plan"
            XCTAssertNil(
                session.permissionModeSurfaceDecision.displayMode,
                "\(agent) has no Claude permission mode, so a probed value must stay invisible."
            )
            XCTAssertFalse(session.permissionModeSurfaceDecision.canCycle)
        }
    }

    func testPermissionModeSurfaceShowsForClaudeWithATerminal() {
        var session = SessionStateFixture.make(agentID: .claudeCode, tty: "ttys004")
        session.permissionMode = "plan"
        let decision = session.permissionModeSurfaceDecision
        XCTAssertEqual(decision.displayMode, "plan")
        XCTAssertTrue(decision.canCycle, "Cycling needs a terminal to send the keystroke to.")
        XCTAssertTrue(decision.shouldProbe)
    }

    func testClaudeWithoutATerminalCannotCycleTheMode() {
        var session = SessionStateFixture.make(agentID: .claudeCode)
        session.permissionMode = "plan"
        let decision = session.permissionModeSurfaceDecision
        XCTAssertEqual(decision.displayMode, "plan", "The mode still shows: it was read from the transcript.")
        XCTAssertFalse(decision.canCycle)
        XCTAssertFalse(decision.shouldProbe)
    }

    func testTmuxSessionIsNeverProbed() {
        var session = SessionStateFixture.make(agentID: .claudeCode, tty: "ttys004")
        session.permissionMode = "plan"
        session.isInTmux = true
        let decision = session.permissionModeSurfaceDecision
        XCTAssertTrue(decision.canCycle)
        XCTAssertFalse(
            decision.shouldProbe,
            "A probe inside tmux reads the wrong pane, so the mode is taken as given."
        )
    }

    // MARK: - Identity keys

    func testSidebarRowKeyCarriesThePhaseSoRowsAreRebuilt() {
        let idle = SessionStateFixture.make(sessionId: "abc", phase: .idle)
        let processing = SessionStateFixture.make(sessionId: "abc", phase: .processing)
        XCTAssertEqual(idle.sidebarRowKey, "abc|idle")
        XCTAssertNotEqual(
            idle.sidebarRowKey,
            processing.sidebarRowKey,
            "Same session, new phase, new key: this is what unsticks a stale attention dot."
        )
    }

    func testStableIdUsesThePidWhenThereIsOne() {
        XCTAssertEqual(SessionStateFixture.make(sessionId: "abc", pid: 42).stableId, "42-abc")
        XCTAssertEqual(SessionStateFixture.make(sessionId: "abc").stableId, "abc")
    }

    // MARK: - Titles

    func testDisplayTitlePrefersTheSessionName() {
        let session = SessionStateFixture.make(
            sessionName: "release triage",
            firstUserMessage: "fix the strip"
        )
        XCTAssertEqual(session.displayTitle, "release triage")
    }

    func testDisplayTitleFallsBackToTheFirstUserMessage() {
        let session = SessionStateFixture.make(firstUserMessage: "fix the pill strip")
        XCTAssertEqual(session.displayTitle, "fix the pill strip")
    }

    func testDisplayTitleCutsALongFirstMessage() {
        let long = String(repeating: "x", count: 120)
        let session = SessionStateFixture.make(firstUserMessage: long)
        XCTAssertEqual(session.displayTitle.count, 50, "A row title has one line, so 50 characters is the cap.")
    }

    func testDisplayTitleFallsBackToTheProjectName() {
        let session = SessionStateFixture.make(cwd: "/Users/tester/agent-visor")
        XCTAssertEqual(session.displayTitle, session.bestProjectName)
    }

    func testBestProjectNamePrefersTheLiveDirectory() {
        var session = SessionStateFixture.make(cwd: "/Users/tester/project")
        XCTAssertEqual(session.bestProjectName, session.projectName)
        session.currentProject = "nested-package"
        XCTAssertEqual(session.bestProjectName, "nested-package")
    }

    // MARK: - Approval

    func testApprovalPhaseExposesThePendingTool() {
        let context = PermissionContext(
            toolUseId: "tooluse_123",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = SessionStateFixture.make(phase: .waitingForApproval(context))

        XCTAssertTrue(session.needsAttention)
        XCTAssertEqual(session.pendingToolName, "Bash")
        XCTAssertEqual(session.pendingToolId, "tooluse_123")
        XCTAssertNotNil(session.activePermission)
    }

    func testIdlePhaseHasNoPendingTool() {
        let session = SessionStateFixture.make(phase: .idle)
        XCTAssertFalse(session.needsAttention)
        XCTAssertNil(session.activePermission)
        XCTAssertNil(session.pendingToolName)
    }

    // MARK: - Image route

    func testImageRouteNeedsAWayToSend() {
        let session = SessionStateFixture.make(agentID: .claudeCode)
        XCTAssertEqual(
            session.imageSubmissionRoute,
            .unavailable,
            "No terminal means no silent send, so the paste path must stay shut."
        )
    }

    func testClaudeWithATerminalTakesTheAttachmentRoute() {
        let session = SessionStateFixture.make(agentID: .claudeCode, tty: "ttys004")
        XCTAssertEqual(session.imageSubmissionRoute, .terminalAttachment)
    }

    func testPiWithATerminalTakesThePathPromptRoute() {
        let session = SessionStateFixture.make(agentID: .pi, tty: "ttys004")
        XCTAssertEqual(
            session.imageSubmissionRoute,
            .terminalPathPrompt,
            "Pi reads a path from the prompt, so it cannot take Claude's attachment route."
        )
    }

    func testCursorHasNoImageRouteEvenWithATerminal() {
        let session = SessionStateFixture.make(agentID: .cursor, tty: "ttys004")
        XCTAssertEqual(session.imageSubmissionRoute, .unavailable)
    }

    // MARK: - Phase mutation

    func testSetPhaseReportsOnlyRealChanges() {
        var session = SessionStateFixture.make(phase: .idle)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(
            session.setPhase(.processing, evidenceSource: .hook, observedAt: observedAt),
            "Idle to processing is a change."
        )
        XCTAssertFalse(
            session.setPhase(.processing, evidenceSource: .hook, observedAt: observedAt),
            """
            Same phase, same evidence, same observation time: nothing changed, so the store must \
            not publish. The time has to be given here, because a later observation of the same \
            phase does count as a change.
            """
        )
    }

    func testALaterObservationOfTheSamePhaseStillCounts() {
        var session = SessionStateFixture.make(phase: .idle)
        session.setPhase(.processing, evidenceSource: .hook, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(
            session.setPhase(.processing, evidenceSource: .hook, observedAt: Date(timeIntervalSince1970: 1_700_000_060)),
            "Fresh evidence for the same phase keeps the session from looking stale."
        )
    }

    func testReattachClearsPhaseEvidence() {
        var session = SessionStateFixture.make(phase: .processing)
        session.markPhaseEvidence(.hook, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(session.phaseObservedAt)
        XCTAssertNotNil(session.phaseEvidenceSource)

        let didChange = session.reattachAsIdleWithoutPhaseEvidence()

        XCTAssertTrue(didChange)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(
            session.phaseObservedAt,
            "A reattached session has no observation, so stale evidence must not survive."
        )
        XCTAssertNil(session.phaseEvidenceSource)
    }

    func testReattachReportsNoChangeWhenAlreadyIdleAndBare() {
        var session = SessionStateFixture.make(phase: .idle)
        XCTAssertFalse(session.reattachAsIdleWithoutPhaseEvidence())
    }

    func testMarkPhaseEvidenceRecordsSourceAndTime() {
        var session = SessionStateFixture.make()
        let observedAt = Date(timeIntervalSince1970: 1_700_000_500)
        session.markPhaseEvidence(.transcriptMarker, observedAt: observedAt)
        XCTAssertEqual(session.phaseEvidenceSource, .transcriptMarker)
        XCTAssertEqual(session.phaseObservedAt, observedAt)
    }
}

/// Behaviour of the tool tracker carried by every session.
final class ToolTrackerBehaviourTests: XCTestCase {
    func testMarkSeenIsTrueOnlyTheFirstTime() {
        var tracker = ToolTracker()
        XCTAssertTrue(tracker.markSeen("tooluse_1"))
        XCTAssertFalse(tracker.markSeen("tooluse_1"))
        XCTAssertTrue(tracker.hasSeen("tooluse_1"))
    }

    func testStartToolTracksOneRunningTool() {
        var tracker = ToolTracker()
        tracker.startTool(id: "tooluse_1", name: "Bash")
        XCTAssertEqual(tracker.inProgress["tooluse_1"]?.name, "Bash")
        XCTAssertEqual(tracker.inProgress["tooluse_1"]?.phase, .running)
    }

    func testStartToolIgnoresARepeatedId() {
        var tracker = ToolTracker()
        tracker.startTool(id: "tooluse_1", name: "Bash")
        tracker.startTool(id: "tooluse_1", name: "Read")
        XCTAssertEqual(
            tracker.inProgress["tooluse_1"]?.name,
            "Bash",
            "A replayed hook must not rename a running tool."
        )
        XCTAssertEqual(tracker.inProgress.count, 1)
    }

    func testCompleteToolRemovesItButKeepsItSeen() {
        var tracker = ToolTracker()
        tracker.startTool(id: "tooluse_1", name: "Bash")
        tracker.completeTool(id: "tooluse_1", success: true)
        XCTAssertTrue(tracker.inProgress.isEmpty)
        XCTAssertTrue(
            tracker.hasSeen("tooluse_1"),
            "A finished tool stays seen, so a late duplicate cannot restart it."
        )
    }

    func testCompletingAnUnknownToolIsHarmless() {
        var tracker = ToolTracker()
        tracker.completeTool(id: "never-started", success: false)
        XCTAssertTrue(tracker.inProgress.isEmpty)
    }
}
