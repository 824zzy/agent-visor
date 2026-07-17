import XCTest

final class SessionStorePhaseMutationAuditTests: XCTestCase {
    func testSessionStoreMutablePhaseWritesGoThroughSetPhase() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(contentsOf: sessionStoreURL(from: testFile))
        let pattern = #"(?m)\b(?:session|sessions\[[^\]]+\]\?)\.phase\s*=(?!=)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        XCTAssertTrue(
            matches.isEmpty,
            "Mutable SessionStore phase writes must use setPhase(...) so phaseChangedAt stays in sync."
        )
    }

    func testObservedPhaseReconcilePublishesWhenInferenceMutatesState() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private func applyInferredObservedPhase(sessionId: String) async -> Bool"),
            "Observed phase inference should report whether it mutated state."
        )
        XCTAssertTrue(
            source.contains("if didChange {\n            publishState()"),
            "Periodic observed phase reconciliation must publish after inferred phase changes."
        )
    }

    func testObservedApprovalCanRecoverFromCompletedTranscript() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("ObservedApprovalRecoveryPolicy.shouldApply"),
            "Observed approval phases must reconcile against terminal transcript evidence."
        )
        XCTAssertFalse(
            source.contains("!session.phase.isWaitingForApproval else { return false }"),
            "Waiting-for-approval must not bypass transcript recovery unconditionally."
        )
    }

    func testApprovalProgressUsesAgentAwareReleasePolicy() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("PendingApprovalCompletionPolicy.shouldReleaseWaitingState("),
            "SessionStore must let observed Codex continuation signals clear a resolved approval."
        )
        XCTAssertTrue(
            source.contains("agentID: session.agentID"),
            "The release decision must remain source-aware so Claude Code keeps strict parallel-tool protection."
        )
    }

    func testSessionStateTracksPhaseEvidenceSeparatelyFromPhaseChanges() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let sessionStateSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionState.swift"))
        let sessionPhaseSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionPhase.swift"))
        let sessionStoreSource = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            sessionPhaseSource.contains("enum SessionPhaseEvidenceSource"),
            "Phase freshness should have an explicit evidence source rather than overloading phaseChangedAt."
        )
        XCTAssertTrue(
            sessionStateSource.contains("var phaseObservedAt: Date?"),
            "SessionState should track when the current phase was last observed, even if the phase did not change."
        )
        XCTAssertTrue(
            sessionStateSource.contains("var phaseEvidenceSource: SessionPhaseEvidenceSource?"),
            "SessionState should track whether phase evidence came from hooks, transcript markers, heuristics, or rediscovery."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("markPhaseEvidence"),
            "Transcript inference should refresh phase evidence on same-phase syncs without forcing a phase transition."
        )
        XCTAssertTrue(
            sessionStateSource.contains("PhaseEvidenceMutationPolicy.didChange"),
            "Same evidence should not trigger a redundant publish on every reconciliation tick."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("guard let transcriptModifiedAt"),
            "Observed phase inference must require real transcript evidence instead of treating a missing file as freshly active."
        )
        XCTAssertFalse(
            sessionStoreSource.contains("var quiescent: TimeInterval = 0"),
            "A missing transcript must not default to zero quiescence and infer a false Processing state."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("session.setPhase(.idle, evidenceSource: .rediscovery, observedAt: now)"),
            "Stale hook evidence should be replaced by explicit rediscovery evidence when Ready expires."
        )
    }

    func testTranscriptMergesRefreshSessionLastActivity() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        let callCount = source.components(separatedBy: "Self.mergedLastActivity(").count - 1

        XCTAssertGreaterThanOrEqual(
            callCount,
            4,
            "Bootstrap, history-load, file-update, and live write-back paths must refresh lastActivity from transcript dates."
        )
        XCTAssertTrue(
            source.contains("private static func mergedLastActivity(current: Date, info: ConversationInfo) -> Date"),
            "SessionStore should centralize transcript activity merging instead of open-coding date precedence."
        )
    }

    func testEndedSessionResurrectionExcludesCurrentPid() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionRebindCandidatePolicy.excludePidForEndedResurrection"),
            "Ended-session resurrection must exclude the current PID so SessionEnd cannot immediately re-open the same process."
        )
    }

    func testClaudeReattachmentRefreshesTheWholeAttachmentAsIdle() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        guard let start = source.range(of: "private func applyClaudeReattachment")?.lowerBound,
              let end = source.range(of: "private static func hasTerminalBootstrapMetadataStatus")?.lowerBound else {
            return XCTFail("Could not isolate applyClaudeReattachment.")
        }
        let helper = String(source[start..<end])

        for required in [
            "session.pid = attachment.pid",
            "session.tty = attachment.tty",
            "session.terminalHost = attachment.terminalHost",
            "session.isInTmux = attachment.isInTmux",
            "session.setPhase(.idle, evidenceSource: .rediscovery)"
        ] {
            XCTAssertTrue(helper.contains(required), "Missing reattachment update: \(required)")
        }
        XCTAssertFalse(
            helper.contains("waitingForInput"),
            "A process attachment proves liveness, not that an agent turn just completed."
        )
    }

    func testHookResurrectionUsesSamePidGuard() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionRebindCandidatePolicy.shouldResurrectEndedSessionFromHook"),
            "Late hook events from the same just-ended PID must not resurrect a deactivated session row."
        )
    }

    func testHookPidDedupRespectsSharedProcessSessions() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        guard let start = source.range(of: "private func processHookEvent")?.lowerBound,
              let end = source.range(of: "private func codexBackedHookEvent")?.lowerBound else {
            return XCTFail("Could not isolate processHookEvent.")
        }
        let hookPath = String(source[start..<end])

        XCTAssertTrue(
            hookPath.contains("HookProcessMetadataPolicy.shouldRemoveCollidingSession"),
            "Hook PID dedup must not collapse Codex/Cursor GUI threads that intentionally share one host process."
        )
        XCTAssertTrue(
            hookPath.contains("HookProcessMetadataPolicy.merge"),
            "A shared-process hook PID is an event-emitter PID, not a replacement for the discovered owner PID."
        )
        XCTAssertFalse(
            hookPath.contains("session.pid = event.pid"),
            "Hook events must not unconditionally replace process identity for shared-process GUI sessions."
        )
    }

    func testPruneReconcilesClaudeTerminalMetadataStatus() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("SessionState.readSessionStatus(pid: session.pid)"),
            "Already-tracked Claude rows must re-read session metadata during pruning; discovery-only filtering cannot hide existing rows."
        )
        XCTAssertTrue(
            source.contains("ClaudeCodeSessionMetadataPolicy.isTerminalStatus"),
            "Pruning should treat ended/deactivated Claude metadata status as a dead-session signal even while the process is winding down."
        )
    }

    func testCodexPrunePassesExplicitArchiveRelocationToRetentionPolicy() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("isExplicitlyArchived = thread.isExplicitlyArchived"),
            "SessionStore must derive the definitive archive signal from the relocated rollout path."
        )
        XCTAssertTrue(
            source.contains("isExplicitlyArchived: isExplicitlyArchived"),
            "Codex retention must receive the explicit archive signal instead of relying only on sqlite archived state."
        )
    }

    func testCursorObservedClaudeRowsPruneThroughTranscriptLivenessPolicy() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private func shouldPruneCursorObservedClaudeSession"),
            "Cursor-hosted Claude rows need their own prune gate; PID-alive alone is not a real session signal for claude-vscode."
        )
        XCTAssertTrue(
            source.contains("CursorHostedSessionLivenessPolicy.classify"),
            "Pruning must use the shared transcript-evidence liveness policy so metadata-only Cursor rows are removed."
        )
        XCTAssertTrue(
            source.contains("session.origin == .cursorObserved"),
            "The prune path should key on the observed host origin, not only agent id or terminal host."
        )
    }

    func testCursorObservedDeadProcessActionRemovesInsteadOfEnding() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let providerSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("AgentProvider.swift"))

        XCTAssertTrue(
            providerSource.contains("session.origin == .cursorObserved"),
            "Observed host sessions without transcript evidence should be removed during prune, not kept as ended rows."
        )
        XCTAssertTrue(
            providerSource.contains("return .remove"),
            "Cursor-observed dead-process action should remove the row outright."
        )
    }

    func testBootstrapDoesNotReviveTerminalClaudeMetadataStatus() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private static func bootstrapPhase("),
            "Bootstrap should centralize initial phase calculation so live discovery cannot bypass terminal Claude metadata status."
        )
        XCTAssertTrue(
            source.contains("SessionState.readSessionStatus(pid: pid)"),
            "Bootstrap must re-read Claude metadata status at merge time; provider discovery can race with session deactivation."
        )
        XCTAssertTrue(
            source.contains("let bootstrapPhase = Self.bootstrapPhase("),
            "Newly bootstrapped sessions should compute a guarded initial phase instead of defaulting every non-historical PID to idle."
        )
        XCTAssertTrue(
            source.contains("phase: bootstrapPhase"),
            "The guarded bootstrap phase should be reused for SessionState creation instead of re-reading metadata inconsistently."
        )
    }

    func testExistingBootstrapRowsOnlyEndForTerminalMetadataStatus() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("if Self.hasTerminalBootstrapMetadataStatus(agentID: info.agentID, pid: info.pid),"),
            "Existing rows should only be ended during bootstrap when Claude metadata says the process is terminal."
        )
        XCTAssertFalse(
            source.contains("if bootstrapPhase == .ended, existing.phase != .ended"),
            "Existing Codex/Cursor rows must not be ended just because a rediscovery result is historical; that causes transient misses to hide active rows."
        )
    }

    func testBootstrapDoesNotFakeCurrentActivityForMissingObservedTranscripts() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertFalse(
            source.contains("var fileDate = Date()"),
            "Bootstrap must not make missing observed transcripts look freshly active by defaulting fileDate to Date()."
        )
        XCTAssertTrue(
            source.contains("let fileDate: Date?"),
            "Bootstrap should represent a missing transcript/rollout mtime as nil."
        )
        XCTAssertTrue(
            source.contains("private static func bootstrapLastActivity("),
            "Bootstrap should centralize missing-metadata lastActivity handling."
        )
        XCTAssertTrue(
            source.contains("session.lastActivity = Self.bootstrapLastActivity("),
            "New sessions should use the guarded bootstrap activity policy instead of assigning a synthetic current date."
        )
    }

    func testCodexFileExtendCanRefreshMetadataWithoutFullReplay() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("CodexFileSyncPolicy.mode("),
            "Codex file-extend handling must use the explicit policy so unopened observed sessions do not full-parse huge rollout files."
        )
        XCTAssertTrue(
            source.contains("applyMetadataOnlyConversationInfo("),
            "Codex metadata-only file sync must refresh sidebar/pill metadata without dispatching a full history replay."
        )
    }

    func testCodexMetadataOnlySyncRefreshesTurnMarkerForPhaseInference() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let sessionStoreSource = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        let summarySource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("CodexConversationSummary.swift"))
        let parserSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("CodexConversationParser.swift"))

        XCTAssertTrue(
            summarySource.contains("let marker: TurnMarker"),
            "Codex lightweight summary parsing should keep the tail turn marker needed by observed phase inference."
        )
        XCTAssertTrue(
            parserSource.contains("func updateLastTurnMarker(sessionId: String, marker: TurnMarker)"),
            "The full Codex parser actor should expose a marker-only update for metadata-only file sync."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("CodexConversationSummary.shared.lastTurnMarker"),
            "Metadata-only Codex sync must refresh the cached turn marker before observed phase inference runs."
        )
    }

    func testCodexMetadataSummaryCarriesLatestTurnContextScanAcrossAppends() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("CodexConversationSummary.swift"))

        XCTAssertTrue(source.contains("CodexRolloutSummaryReader.read("))
        XCTAssertTrue(source.contains("previousTurnContextScan: cached?.turnContextScan"))
        XCTAssertFalse(source.contains("JSONLHeadTailFileReader.read(path: path)"))
    }

    func testCodexFileExtendFastSyncsPhaseBeforeFullReplay() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private func refreshCodexMetadataBeforeFullReplay"),
            "Codex file-extend handling should have a fast metadata/marker sync path before expensive full replay."
        )
        guard let fastSyncRange = source.range(of: "refreshCodexMetadataBeforeFullReplay") else {
            return XCTFail("Missing Codex fast-sync helper call.")
        }
        guard let fullReplayRange = source.range(of: "provider.fileSync") else {
            return XCTFail("Missing provider.fileSync call.")
        }
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: fastSyncRange.lowerBound),
            source.distance(from: source.startIndex, to: fullReplayRange.lowerBound),
            "Codex metadata/marker sync should run before provider.fileSync so status pills update before large rollout replay."
        )
    }

    func testHookLifecycleUsesSharedTerminalStatusPolicy() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = repoRootURL(from: testFile)
        let sessionEventSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionEvent.swift"))
        let sessionStoreSource = try String(contentsOf: sessionStoreURL(from: testFile))
        let monitorSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("ClaudeSessionMonitor.swift"))

        XCTAssertTrue(
            sessionEventSource.contains("var isTerminalLifecycleStatus"),
            "HookEvent should expose one terminal lifecycle predicate instead of scattering status string checks."
        )
        XCTAssertTrue(
            sessionEventSource.contains("ClaudeCodeSessionMetadataPolicy.isTerminalStatus(status)"),
            "Claude hook status handling must share the metadata terminal-status policy so deactivated/ended semantics cannot drift."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("event.isTerminalLifecycleStatus"),
            "SessionStore should use HookEvent.isTerminalLifecycleStatus when ending hook-driven sessions."
        )
        XCTAssertTrue(
            monitorSource.contains("event.isTerminalLifecycleStatus"),
            "ClaudeSessionMonitor should stop watchers for every terminal hook status, not only literal ended."
        )
    }

    func testPermissionContextIsNonisolatedForHookPhaseInference() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let sessionPhaseSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionPhase.swift"))

        XCTAssertTrue(
            sessionPhaseSource.contains("nonisolated init("),
            "PermissionContext is a Sendable value constructed from nonisolated hook phase inference; its initializer must not be MainActor-isolated."
        )
    }

    func testSessionValueHelpersUsedByStoreAreNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let sessionStateSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionState.swift"))
        let sessionPhaseSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("SessionPhase.swift"))

        for required in [
            "nonisolated var id: String",
            "nonisolated var sidebarRowKey: String",
            "nonisolated mutating func setPhase",
            "nonisolated static func readSessionName",
            "nonisolated static func readLaunchCwd",
            "nonisolated static func readSessionStatus",
            "nonisolated var activePermission",
            "nonisolated var lastMessageRole"
        ] {
            XCTAssertTrue(
                sessionStateSource.contains(required),
                "SessionState helper '\(required)' is used from SessionStore/background paths and must not inherit MainActor isolation."
            )
        }

        for required in [
            "nonisolated var formattedInput",
            "nonisolated var needsAttention",
            "nonisolated var isActive",
            "nonisolated var displayPriority",
            "nonisolated var isWaitingForApproval",
            "nonisolated var approvalToolName"
        ] {
            XCTAssertTrue(
                sessionPhaseSource.contains(required),
                "SessionPhase/PermissionContext helper '\(required)' is used from SessionStore/background paths and must not inherit MainActor isolation."
            )
        }
    }

    func testProviderDiscoveryHelpersUsedOffMainAreNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let cursorProviderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CursorAgentProvider.swift"))
        let codexProviderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAgentProvider.swift"))
        let codexThreadStoreSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexThreadStore.swift"))
        let codexOwnershipStoreSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAgentVisorOwnershipStore.swift"))
        let discoveryUtilitiesSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("AgentDiscoveryUtilities.swift"))
        let processExecutorSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Shared")
            .appendingPathComponent("ProcessExecutor.swift"))
        let settingsSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Core")
            .appendingPathComponent("Settings.swift"))
        let liveReaderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("LiveProcessInfoReader.swift"))

        XCTAssertTrue(
            cursorProviderSource.contains("nonisolated func transcriptURL"),
            "Cursor transcript resolution is called from nonisolated async provider paths."
        )
        XCTAssertTrue(
            codexProviderSource.contains("nonisolated static func activeGUIThreadIDs"),
            "Codex GUI active-set discovery is called by background prune/discovery paths."
        )
        XCTAssertTrue(
            codexThreadStoreSource.contains("nonisolated static func liveThreadCandidates"),
            "Codex thread-store reads are used by background discovery and prune."
        )
        XCTAssertTrue(
            codexThreadStoreSource.contains("nonisolated private struct ThreadRow: Decodable, Sendable"),
            "SQLite JSON decode row types must stay nonisolated because queryThreads runs off the MainActor."
        )
        XCTAssertTrue(
            codexThreadStoreSource.contains("CodexSessionIndexTitleParser.titlesByThreadId"),
            "Codex session-index title parsing must stay in Core/pure code because title lookup runs off the MainActor."
        )
        XCTAssertTrue(
            codexThreadStoreSource.contains("liveThreadCandidate(id: id)"),
            "Per-thread lookups should consult the bounded live snapshot before spawning an id-specific sqlite query."
        )
        XCTAssertTrue(
            codexThreadStoreSource.contains("sessionIndexTitles: entry.titles"),
            "A query cache hit must reuse its title map instead of reparsing session_index.jsonl for every row lookup."
        )
        XCTAssertTrue(
            codexOwnershipStoreSource.contains("nonisolated static func isClaimed"),
            "Codex ownership checks are used while classifying nonisolated Codex discovery results."
        )
        XCTAssertTrue(
            processExecutorSource.contains("nonisolated static let shared"),
            "ProcessExecutor.shared is used by nonisolated discovery helpers."
        )
        XCTAssertTrue(
            processExecutorSource.contains("nonisolated final class ProcessExecutor: @unchecked Sendable, ProcessExecuting"),
            "ProcessExecutor is stateless and must not inherit default MainActor isolation through an actor or class boundary."
        )
        XCTAssertTrue(
            settingsSource.contains("nonisolated static var observedWindowSeconds"),
            "Observed-agent recency settings are read by background discovery and prune."
        )
        XCTAssertTrue(
            discoveryUtilitiesSource.contains("nonisolated static func writeLog"),
            "Provider discovery logging runs from background queues."
        )
        XCTAssertTrue(
            liveReaderSource.contains("final class LiveProcessInfoReader: @unchecked Sendable, ProcessInfoReader"),
            "The process-info reader crosses actor/background boundaries through ProcessInfoReader."
        )
        XCTAssertTrue(
            liveReaderSource.contains("nonisolated static let shared"),
            "LiveProcessInfoReader.shared is read from SessionStore and background discovery paths."
        )
    }

    func testCodexApprovalBridgeHandlersDoNotCaptureWeakSelf() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let bridgeSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAppServerApprovalBridge.swift"))

        XCTAssertFalse(
            bridgeSource.contains("[weak self]"),
            "Codex app-server handlers are @Sendable and long-lived; route through the singleton instead of capturing weak self into a Task."
        )
        XCTAssertTrue(
            bridgeSource.contains("CodexAppServerApprovalBridge.shared.handle"),
            "Server-request handling should use the shared bridge on the MainActor so the Sendable closure does not capture mutable self."
        )
    }

    func testCodexAppServerHandlersInitializerIsNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let clientSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAppServerClient.swift"))

        XCTAssertTrue(
            clientSource.contains("nonisolated init("),
            "CodexAppServerHandlers is stored inside an actor and must have an explicit nonisolated initializer under default MainActor isolation."
        )
    }

    func testSessionSenderLoggerIsNonisolatedForBackgroundSendPath() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let senderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Chat")
            .appendingPathComponent("SessionSender.swift"))

        XCTAssertTrue(
            senderSource.contains("nonisolated private static let logger"),
            "SessionSender logs from a DispatchQueue Sendable closure; its logger must not inherit MainActor isolation."
        )
    }

    func testChatModeProbeDoesNotReadMonitorInstancesFromTimerClosure() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let chatViewSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("ChatView.swift"))

        XCTAssertFalse(
            chatViewSource.contains("capturedMonitor.instances"),
            "Mode probing runs from a timer closure; it should fetch a Sendable session snapshot through SessionStore instead of reading MainActor monitor state."
        )
        XCTAssertTrue(
            chatViewSource.contains("SessionStore.shared.getSession(id: capturedSessionId)"),
            "Mode probing should snapshot the live session through the SessionStore actor before dispatching off-main AX reads."
        )
    }

    func testSendableStaticConstantsDoNotUseUnsafeNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let processExecutorSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Shared")
            .appendingPathComponent("ProcessExecutor.swift"))
        let cursorTitleStoreSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("CursorSessionTitleStore.swift"))
        let spawnedManagerSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("SpawnedSessionManager.swift"))

        XCTAssertFalse(
            processExecutorSource.contains("nonisolated(unsafe) static let shared"),
            "Actor singleton constants should rely on normal static-let isolation; nonisolated(unsafe) triggers stricter Swift warnings."
        )
        XCTAssertFalse(
            cursorTitleStoreSource.contains("nonisolated(unsafe) private static let shadowLock"),
            "Sendable NSLock constants do not need nonisolated(unsafe); keep the unsafe marker only on mutable shadow state."
        )
        XCTAssertTrue(
            cursorTitleStoreSource.contains("nonisolated private static let shadowLock"),
            "The Cursor title shadow lock is used from nonisolated accessors and must stay nonisolated."
        )
        XCTAssertFalse(
            spawnedManagerSource.contains("nonisolated(unsafe) private static let claimedLock"),
            "Sendable NSLock constants do not need nonisolated(unsafe); keep the unsafe marker only on mutable claimed-ID state."
        )
        XCTAssertTrue(
            spawnedManagerSource.contains("nonisolated private static let claimedLock"),
            "The spawned-session claimed-ID lock is used from nonisolated accessors and must stay nonisolated."
        )
    }

    func testSingletonCallbacksDoNotCaptureWeakSelfIntoMainActorTask() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let titleWatcherSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("CursorSessionTitleWatcher.swift"))
        let hotkeyManagerSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Events")
            .appendingPathComponent("HotkeyManager.swift"))

        XCTAssertFalse(
            titleWatcherSource.contains("Task { @MainActor in self?"),
            "Timer callbacks are concurrently-executing closures; singleton watchers should route through shared instead of capturing weak self into a MainActor task."
        )
        XCTAssertTrue(
            titleWatcherSource.contains("CursorSessionTitleWatcher.shared.redetect()"),
            "The title watcher timer should re-enter through the app-lifetime singleton."
        )
        XCTAssertFalse(
            hotkeyManagerSource.contains("Task { @MainActor in self?"),
            "Global event callbacks are concurrently-executing closures; singleton managers should route through shared instead of capturing weak self into a MainActor task."
        )
        XCTAssertTrue(
            hotkeyManagerSource.contains("HotkeyManager.shared.handle(event)"),
            "The hotkey global monitor should re-enter through the app-lifetime singleton."
        )
    }

    func testChatViewDoesNotShipGapDebugInstrumentation() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let chatViewSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Views")
            .appendingPathComponent("ChatView.swift"))

        XCTAssertFalse(
            chatViewSource.contains("GapDebug"),
            "ChatView should not keep transient gap-debug loggers in hot render/history paths."
        )
        XCTAssertFalse(
            chatViewSource.contains("[DEBUG-gap]"),
            "ChatView should not emit transient debug markers in the dev build."
        )
    }

    func testClaudeSessionMonitorBackgroundHelpersAreNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let monitorSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("ClaudeSessionMonitor.swift"))

        XCTAssertTrue(
            monitorSource.contains("nonisolated static func discoverExistingSessions()"),
            "Session discovery runs from a background queue and must not inherit ClaudeSessionMonitor's MainActor isolation."
        )
        XCTAssertTrue(
            monitorSource.contains("nonisolated private static func writeLog"),
            "Discovery/fallback logging runs from background queues and must not inherit ClaudeSessionMonitor's MainActor isolation."
        )
    }

    func testCodexMetadataWatcherRearmsDeletedOrRenamedFiles() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexThreadStore.swift"))
        let sessionStoreSource = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))

        XCTAssertTrue(
            source.contains("let existingPaths = Set(paths.filter { FileManager.default.fileExists(atPath: $0) })"),
            "Codex metadata watcher must distinguish missing files from desired watch paths so deleted/renamed WAL/index files can be rearmed."
        )
        XCTAssertTrue(
            source.contains("for path in watchers.keys where !existingPaths.contains(path)"),
            "Codex metadata watcher must stop watchers whose underlying file disappeared instead of keeping stale file descriptors."
        )
        XCTAssertTrue(
            source.contains("let handleToClose = handle"),
            "File watcher cancel handlers should close the handle they registered, not whichever handle happens to be current later."
        )
        XCTAssertFalse(
            source.contains("try? self?.fileHandle?.close()"),
            "Closing self.fileHandle from a cancel handler can close the replacement handle after a watcher restart."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("CodexMetadataWatcher.shared.start()"),
            "Periodic rediscovery should also rearm Codex metadata watchers so files created after launch are observed."
        )
    }

    func testSessionStoreBackgroundUtilityEntrypointsAreNonisolated() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let toolEventSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("State")
            .appendingPathComponent("ToolEventProcessor.swift"))
        let pendingPermissionSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Hooks")
            .appendingPathComponent("PendingPermissionStore.swift"))
        let adapterRegistrySource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("TerminalAdapterRegistry.swift"))
        let iTermProbeSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("ITermModeProbe.swift"))
        let ghosttyProbeSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("GhosttyModeProbe.swift"))
        let rebinderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Session")
            .appendingPathComponent("ClaudeSessionPidRebinder.swift"))
        let modeCyclerSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Navigation")
            .appendingPathComponent("PermissionModeCycler.swift"))
        let toolResultDataSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Models")
            .appendingPathComponent("ToolResultData.swift"))

        for required in [
            "nonisolated private static let logger",
            "nonisolated static func extractToolInput",
            "nonisolated private static func attachSubagentToolsToTask"
        ] {
            XCTAssertTrue(
                toolEventSource.contains(required),
                "ToolEventProcessor helper '\(required)' is called from SessionStore actor/background paths."
            )
        }
        XCTAssertTrue(
            pendingPermissionSource.contains("nonisolated static func delete"),
            "PendingPermissionStore.delete is called from JSONL update handling inside SessionStore."
        )
        XCTAssertTrue(
            adapterRegistrySource.contains("nonisolated static func adapter"),
            "Terminal adapter selection is used by detached assistant-text scraping."
        )
        XCTAssertTrue(
            iTermProbeSource.contains("nonisolated static func readScrollback"),
            "iTerm scrollback scraping runs from a nonisolated detached path."
        )
        XCTAssertTrue(
            ghosttyProbeSource.contains("nonisolated static func readScrollback"),
            "Ghostty scrollback scraping runs from a nonisolated detached path."
        )
        XCTAssertTrue(
            ghosttyProbeSource.contains("nonisolated private static let logger"),
            "Ghostty mode-probe logging is used from nonisolated helper paths."
        )
        XCTAssertTrue(
            rebinderSource.contains("nonisolated static func findLiveAttachment"),
            "Session rebinding runs during SessionStore pruning and must not inherit MainActor isolation."
        )
        for required in [
            "nonisolated private static let logger",
            "nonisolated private static func selectItermSession",
            "nonisolated private static func focusSessionPane",
            "nonisolated private static func writeOSC7",
            "nonisolated private static func runAppleScript"
        ] {
            XCTAssertTrue(
                modeCyclerSource.contains(required),
                "PermissionModeCycler helper '\(required)' is called from detached nonisolated delivery paths."
            )
        }
        for required in [
            "nonisolated struct MCPResult",
            "nonisolated struct GenericResult",
            "nonisolated init(serverName: String, toolName: String, rawResult: [String: Any])",
            "nonisolated init(rawContent: String?, rawData: [String: Any]?)"
        ] {
            XCTAssertTrue(
                toolResultDataSource.contains(required),
                "Structured-result DTO initializer '\(required)' is called from nonisolated transcript parsing."
            )
        }
    }

    func testCodexHookPrefersStableThreadIdentifiersOverTurnIdentifiers() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Resources")
            .appendingPathComponent("agent-visor-codex-state.py"))

        XCTAssertTrue(
            source.contains("first(data, \"thread_id\", \"conversation_id\", \"session_id\")"),
            "Codex hook payloads can expose per-turn values in session_id; Agent Visor must prefer stable thread/conversation ids before falling back."
        )
        XCTAssertFalse(
            source.contains("first(data, \"session_id\", \"thread_id\", \"conversation_id\")"),
            "The old Codex hook id priority can turn a turn_id into a phantom Agent Visor session."
        )
    }

    func testCodexHookEventsCannotCreateSessionsForUnknownThreadIds() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        let codexProviderSource = try String(contentsOf: root
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("Agents")
            .appendingPathComponent("CodexAgentProvider.swift"))

        XCTAssertTrue(
            source.contains("private func codexBackedHookEvent(_ event: HookEvent) -> HookEvent?"),
            "SessionStore should centralize Codex hook validation so per-turn hook ids cannot create phantom sessions."
        )
        XCTAssertTrue(
            source.contains("guard let event = codexBackedHookEvent(event) else { return }"),
            "processHookEvent must drop unknown Codex hook ids before creating or syncing a session."
        )
        XCTAssertTrue(
            source.contains("CodexThreadStore.thread(id: event.sessionId) == nil"),
            "The Codex hook guard should validate the id against CodexThreadStore before SessionStore trusts it."
        )
        XCTAssertTrue(
            codexProviderSource.contains("nonisolated static func rolloutFileURL(sessionId: String"),
            "The Codex hook guard needs a rollout-file fallback so a valid new thread is not dropped while sqlite is catching up."
        )
        XCTAssertTrue(
            source.contains("CodexAgentProvider.rolloutFileURL(sessionId: event.sessionId) == nil"),
            "Unknown Codex hook ids should be dropped only when neither sqlite nor the rollout filename can prove they are real thread ids."
        )
    }

    func testBootstrapSummaryImmediatelyReconcilesObservedPhase() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("private func applyBootstrapConversationInfo(sessionId: String, info: ConversationInfo) async"),
            "Bootstrap summary application should be async so it can resolve observed-session phase before publishing."
        )
        XCTAssertTrue(
            source.contains("_ = await applyInferredObservedPhase(sessionId: sessionId)"),
            "Observed Codex/Cursor sessions should not wait for the periodic reconciler to leave the bootstrap idle phase."
        )
    }

    func testTranscriptDrivenHookPhasesUseObservedHookPhasePolicy() throws {
        let source = try String(contentsOf: sessionStoreURL(from: URL(fileURLWithPath: #filePath)))
        XCTAssertTrue(
            source.contains("ObservedHookPhasePolicy.shouldApplyHookPhase("),
            "Codex GUI and other transcript-driven sessions should not let stale hook waiting_for_input/idle statuses override transcript markers."
        )
        XCTAssertTrue(
            source.contains("reportedHookPhase(for: newPhase)"),
            "SessionStore should map SessionPhase into the pure hook-phase policy instead of open-coding phase cases."
        )
    }

    private func sessionStoreURL(from testFile: URL) -> URL {
        repoRootURL(from: testFile)
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("Services")
            .appendingPathComponent("State")
            .appendingPathComponent("SessionStore.swift")
    }

    private func repoRootURL(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
