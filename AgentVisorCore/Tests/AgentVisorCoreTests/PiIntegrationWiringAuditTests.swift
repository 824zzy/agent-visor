import XCTest

final class PiIntegrationWiringAuditTests: XCTestCase {
    func testPiProviderIsRegisteredWithFallbackDiscoveryAndTranscriptParsing() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let registry = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/AgentRegistry.swift"
        ))
        let provider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"
        ))

        XCTAssertTrue(registry.contains("PiAgentProvider()"))
        XCTAssertTrue(provider.contains("PiProcessSessionMatcher.match"))
        XCTAssertTrue(provider.contains("PiConversationParser.shared.loadHistory"))
        XCTAssertTrue(provider.contains("guard Self.isPiAvailable() else { return }"))
        XCTAssertTrue(provider.contains("try? installHooks()"))
        XCTAssertTrue(provider.contains("line.count + 1"), "Header-only Pi sessions must not appear as history")
        XCTAssertTrue(provider.contains("appendingPathComponent(\".pi\")"))
    }

    func testSettingsDistinguishesNotDetectedObservingAndConnected() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let settings = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/SettingsWindowView.swift"
        ))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(settings.contains("PiConnectionStatePolicy.state"))
        XCTAssertTrue(settings.contains("Pi — Not detected"))
        XCTAssertTrue(settings.contains("Pi — Observing"))
        XCTAssertTrue(settings.contains("Pi — Connected"))
        // The store tells the provider that its runtime reported in; the Pi
        // provider owns the flag, because the flag is Pi's own note.
        XCTAssertTrue(store.contains("noteRuntimeReportedIn()"))
        let piProvider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"))
        XCTAssertTrue(piProvider.contains("PiIntegrationMonitor.shared.recordHeartbeat"))
    }

    func testEndedPiSessionCanRecoverFromLivePostEndTranscriptEvidence() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(store.contains("PiEndedSessionRecoveryPolicy.shouldRecover"))
        XCTAssertTrue(store.contains("evidenceSource: .transcriptMarker"))
    }

    func testPiConversationInfoUsesPiModelCatalogContextWindow() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let parser = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiConversationParser.swift"
        ))

        XCTAssertTrue(parser.contains("appendingPathComponent(\"models-store.json\")"))
        XCTAssertTrue(parser.contains("PiModelCatalogResolver.metadata("))
        XCTAssertTrue(parser.contains("lastModelDisplayName: catalogMetadata?.displayName"))
        XCTAssertTrue(parser.contains("lastContextWindowTokens: catalogMetadata?.contextWindowTokens"))
    }

    func testPiUsesTranscriptInferenceOnlyUntilHookEvidenceArrives() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(store.contains("case .pi:"))
        XCTAssertTrue(store.contains("return s.phaseEvidenceSource != .hook"))
        XCTAssertTrue(store.contains("PiConversationParser.shared.lastTurnMarker"))
        XCTAssertTrue(store.contains("event.agentID == .pi && event.event == \"SessionStart\""))
    }

    func testSessionFileWatcherUsesProviderResolvedPiTranscript() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let watcher = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/SessionFileWatcher.swift"
        ))

        XCTAssertTrue(watcher.contains("AgentRegistry.provider(for: agentID)"))
        XCTAssertTrue(watcher.contains("provider.transcriptURL(sessionId: sessionId, cwd: cwd).path"))
    }

    func testWindowChatGroupsPiTurnsByDefaultWithRawStreamEscapeHatch() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let chat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/ChatView.swift"
        ))
        let windowChat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowChatView.swift"
        ))
        let settings = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/SettingsWindowView.swift"
        ))

        XCTAssertTrue(chat.contains("func piGroupedTimelineRows"))
        XCTAssertTrue(chat.contains("PiTurnGrouper.group"))
        XCTAssertTrue(windowChat.contains("session?.agentID == .pi"))
        XCTAssertTrue(windowChat.contains("collapsePiTurns"))
        XCTAssertTrue(windowChat.contains("piGroupedTimelineRows"))
        XCTAssertTrue(settings.contains("Group Pi turns"))
        XCTAssertTrue(settings.contains("keyPath: \\.collapsePiTurns"))
    }

    func testPiWorkedHeaderCountsActionsWithoutCountingReasoning() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(table.contains("PiTurnActivitySummarizer.summarize"))
        XCTAssertTrue(table.contains("turnCountLabel"))
        XCTAssertTrue(table.contains("countLabel: row.turnCountLabel"))
    }

    func testPiReasoningIsNestedAndMarkdownRendered() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let chat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/ChatView.swift"
        ))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(chat.contains("PiReasoningGroupView"))
        XCTAssertTrue(chat.contains("makePiReasoningGroup"))
        XCTAssertTrue(chat.contains("Reasoning ("))
        XCTAssertTrue(chat.contains("MarkdownText(markdown"))
        XCTAssertTrue(table.contains("PiReasoningGroupView.sentinelToolName"))
    }

    func testPiToolRowsUseProviderAwarePresentation() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let chat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/ChatView.swift"
        ))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(chat.contains("ToolPresentationPolicy.presentation"))
        XCTAssertTrue(chat.contains("agent: agentID"))
        XCTAssertTrue(table.contains("agentID: agentID"))
        XCTAssertTrue(table.contains("agentID: row.agentID"))
    }

    func testExpandedPiWorkBatchesAdjacentActionsWithDrillDown() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(table.contains("PiToolBatchPlanner.groups"))
        XCTAssertTrue(table.contains("batchedItems"))
        XCTAssertTrue(table.contains("PiToolBatchView"))
        XCTAssertTrue(table.contains("MessageItemView("))
        XCTAssertTrue(table.contains("@Environment(\\.openToolDetail)"))
        XCTAssertTrue(table.contains(".environment(\\.openToolDetail, openToolDetail)"))
    }

    func testPiPaginationAlignsToPromptBoundaries() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let windowChat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowChatView.swift"
        ))

        XCTAssertTrue(windowChat.contains("sliceAlignedToPrompt"))
        XCTAssertTrue(windowChat.contains("promptIndices"))
        XCTAssertTrue(windowChat.contains("collapsePiTurns"))
    }

    func testGroupedLivePiTurnSuppressesDuplicateProcessingIndicator() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let windowChat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowChatView.swift"
        ))

        XCTAssertTrue(windowChat.contains("hasLiveTurnHeader"))
        XCTAssertTrue(windowChat.contains("!viewModel.hasLiveTurnHeader"))
    }

    func testPiConversationProseUsesSharedChatContentRail() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let chat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/ChatView.swift"
        ))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(table.contains("MainContentRailLayout.resolve"))
        XCTAssertFalse(chat.contains("ChatMessageReadableWidth"))
    }

    func testExpandedPiWorkRowsAreVisuallyNested() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(table.contains("row.agentID == .pi && row.groupingDepth == 1"))
        XCTAssertTrue(table.contains(".padding(.leading, workIndent)"))
    }

    func testCollapsedPiWorkPinsFailuresAndApprovals() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let table = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/ChatTableView.swift"
        ))

        XCTAssertTrue(table.contains("alwaysVisibleChildren:"))
        XCTAssertTrue(table.contains("piAlwaysVisibleIssueIds"))
        XCTAssertTrue(table.contains(".waitingForApproval"))
    }

    func testPiTranscriptRenameIsAuthoritativeInSharedMetadataMerge() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let providerProtocol = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/AgentProvider.swift"
        ))
        let piProvider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"
        ))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(providerProtocol.contains("transcriptTitleAuthority"))
        XCTAssertTrue(providerProtocol.contains("SessionTranscriptTitlePolicy.Authority"))
        XCTAssertTrue(piProvider.contains("transcriptTitleAuthority"))
        XCTAssertTrue(piProvider.contains(".authoritative"))

        guard let start = store.range(of: "private func applyConversationMetadata")?.lowerBound,
              let end = store.range(of: "private func debugLog", range: start..<store.endIndex)?.lowerBound else {
            return XCTFail("Could not isolate the shared conversation metadata merge.")
        }
        let metadataMerge = String(store[start..<end])
        XCTAssertTrue(metadataMerge.contains("authority:"))
        XCTAssertTrue(metadataMerge.contains("transcriptTitleAuthority"))
    }

    func testLivePiHookMakesAPreviouslyHistoricalSessionTextSendable() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))
        guard let start = store.range(of: "private func processHookEvent")?.lowerBound,
              let end = store.range(of: "private func codexBackedHookEvent")?.lowerBound else {
            return XCTFail("Could not isolate processHookEvent.")
        }
        let hookPath = String(store[start..<end])

        guard let metadataMerge = hookPath.range(of: "HookProcessMetadataPolicy.merge")?.lowerBound,
              let originRefresh = hookPath.range(
                of: "session.origin = SessionStore.originForHostedSession"
              )?.lowerBound else {
            return XCTFail(
                "A live hook must refresh stale historical origin metadata after merging its PID/TTY."
            )
        }

        XCTAssertLessThan(metadataMerge, originRefresh)
        XCTAssertTrue(hookPath.contains("tty: processMetadata.tty"))
        XCTAssertTrue(hookPath.contains("agentID: event.agentID"))
    }

    func testPiComposerUsesProviderAwareImagePathSubmission() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let sender = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Chat/SessionSender.swift"
        ))
        let imageSender = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Chat/ImagePasteSender.swift"
        ))
        let composer = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowComposer.swift"
        ))

        // The route itself is covered by behaviour now, in SessionStateBehaviourTests: no terminal
        // gives no route, Claude with a terminal attaches, Pi with a terminal prompts with a path,
        // and Cursor has no route at all.

        for source in [composer] {
            XCTAssertTrue(source.contains("guard session.imageSubmissionRoute != .unavailable else { return }"))
            XCTAssertTrue(source.contains("ImageAttachmentRetentionPolicy.cleanupDelay("))
            XCTAssertFalse(source.contains("guard session.agentID != .pi else { return }"))
        }
        XCTAssertTrue(sender.contains("case .terminalPathPrompt:"))
        XCTAssertTrue(sender.contains("PiImagePromptComposer.compose("))
        XCTAssertTrue(sender.contains("imagePaths: attachments.map { $0.url.path }"))
        XCTAssertTrue(sender.contains("postImageDeliveryFailure(for: session)"))
        XCTAssertFalse(sender.contains("let effectiveAttachments = session.agentID == .pi ? [] : attachments"))
        XCTAssertTrue(imageSender.contains("ImageAttachmentRetentionPolicy.staleFileAge"))
    }

    func testPiWindowComposerEchoesTheExactPathPromptBeforeTranscriptSync() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let composer = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowComposer.swift"
        ))

        XCTAssertTrue(composer.contains("let pendingEchoText: String?"))
        XCTAssertTrue(composer.contains("case .terminalPathPrompt:"))
        XCTAssertTrue(composer.contains("PiImagePromptComposer.compose("))
        XCTAssertTrue(composer.contains("imagePaths: currentAttachments.map { $0.url.path }"))
        XCTAssertTrue(composer.contains("PendingEchoStore.shared.push(sessionId: session.sessionId, text: pendingEchoText)"))
    }

    func testPiUsesTheSharedWindowChatWithProviderAwareImageInput() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let providerProtocol = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/AgentProvider.swift"
        ))
        let piProvider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"
        ))
        let browserModel = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/MainWindowViewModel.swift"
        ))
        let workspace = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/SessionWorkspaceDetail.swift"
        ))
        let windowChat = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowChatView.swift"
        ))
        let composer = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowComposer.swift"
        ))
        let sender = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Chat/SessionSender.swift"
        ))

        XCTAssertTrue(providerProtocol.contains("nonisolated var canRenderChat: Bool { get }"))
        XCTAssertTrue(providerProtocol.contains("nonisolated var canRenderChat: Bool { false }"))
        XCTAssertTrue(piProvider.contains("nonisolated let canRenderChat = true"))
        XCTAssertTrue(browserModel.contains("canEnterChat: provider?.canRenderChat == true"))
        XCTAssertTrue(workspace.contains("ChatViewHost(sessionId: sessionId)"))
        XCTAssertTrue(windowChat.contains("WindowComposer("))
        XCTAssertFalse(workspace.contains("session.agentID == .claudeCode"))
        XCTAssertTrue(composer.contains("guard session.imageSubmissionRoute != .unavailable else { return }"))
        XCTAssertTrue(sender.contains("PiImagePromptComposer.compose("))
    }

    func testBundledPiExtensionMaintainsOneSessionScopedHeartbeat() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Resources/agent-visor-pi.ts.txt"
        ))

        XCTAssertTrue(source.contains("const HEARTBEAT_INTERVAL_MS = 10_000;"))
        XCTAssertEqual(
            source.components(separatedBy: "setInterval(").count - 1,
            1,
            "Each loaded extension runtime must create at most one heartbeat timer."
        )
        XCTAssertTrue(source.contains("function startHeartbeat(ctx: ExtensionContext): void"))
        XCTAssertTrue(source.contains("if (ctx.mode !== \"tui\") return;"))
        XCTAssertTrue(source.contains(
            "report(ctx, \"SessionHeartbeat\", \"alive\", { idle: runtimeIsIdle(ctx) })"
        ))
        XCTAssertTrue(source.contains("HEARTBEAT_INTERVAL_MS"))
        XCTAssertTrue(source.contains("heartbeatTimer.unref()"))
        XCTAssertTrue(source.contains("clearInterval(heartbeatTimer)"))
        XCTAssertTrue(source.contains("heartbeatTimer = undefined"))

        guard let sessionStart = source.range(of: "pi.on(\"session_start\"")?.lowerBound,
              let startCall = source.range(of: "startHeartbeat(ctx)", range: sessionStart..<source.endIndex)?.lowerBound,
              let shutdownStart = source.range(of: "pi.on(\"session_shutdown\"")?.lowerBound,
              let shutdownEnd = source.range(of: "  });", range: shutdownStart..<source.endIndex)?.upperBound else {
            return XCTFail("Could not isolate heartbeat startup and shutdown wiring.")
        }
        XCTAssertGreaterThan(startCall, sessionStart)

        let shutdown = String(source[shutdownStart..<shutdownEnd])
        guard let stop = shutdown.range(of: "stopHeartbeat()")?.lowerBound,
              let endReport = shutdown.range(of: "report(ctx, \"SessionEnd\", \"ended\")")?.lowerBound else {
            return XCTFail("Session shutdown must stop the timer and then report the terminal lifecycle event.")
        }
        XCTAssertLessThan(stop, endReport)
        XCTAssertFalse(source.contains("writeFile"))
        XCTAssertFalse(source.contains("appendFile"))
        XCTAssertFalse(source.contains("heartbeatQueue"))
    }

    func testBundledPiExtensionReportsLifecycleMetadataOnly() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Resources/agent-visor-pi.ts.txt"
        ))

        XCTAssertTrue(source.contains("pi.on(\"agent_start\""))
        XCTAssertTrue(source.contains("pi.on(\"agent_settled\""))
        XCTAssertTrue(source.contains("pi.on(\"session_shutdown\""))
        XCTAssertTrue(source.contains("pi.on(\"session_before_compact\""))
        XCTAssertTrue(
            source.contains("pi.on(\"session_compact\""),
            "A manual /compact never reaches agent_settled, so the closing compaction boundary must be reported."
        )
        XCTAssertTrue(
            source.contains("report(ctx, \"PostCompact\", idle === false ? \"processing\" : \"idle\""),
            "Compaction completion must only stay Working while the runtime itself reports busy."
        )
        XCTAssertTrue(source.contains("/tmp/agent-visor.sock"))
        XCTAssertTrue(source.contains("agent: \"pi\""))
        XCTAssertTrue(source.contains("session_file: ctx.sessionManager.getSessionFile()"))
        XCTAssertTrue(
            source.contains("is_idle: options.idle"),
            "The runtime idle flag is lifecycle metadata and travels on the existing payload."
        )
        XCTAssertFalse(source.contains("fetch("))
        XCTAssertFalse(source.contains("registerTool"))
        XCTAssertFalse(source.contains("registerCommand"))
        XCTAssertFalse(source.contains("event.prompt"))
        XCTAssertFalse(source.contains("event.message"))
        XCTAssertFalse(source.contains("event.input"))
        XCTAssertFalse(source.contains("event.content"))
    }

    func testBundledPiExtensionProbesTheRuntimeIdleFlagDefensively() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Resources/agent-visor-pi.ts.txt"
        ))

        guard let probeStart = source.range(of: "function runtimeIsIdle(")?.lowerBound,
              let probeEnd = source.range(of: "\n}", range: probeStart..<source.endIndex)?.upperBound else {
            return XCTFail("The extension must resolve the runtime idle flag through one shared probe.")
        }
        let probe = String(source[probeStart..<probeEnd])

        XCTAssertTrue(
            probe.contains("if (typeof probe !== \"function\") return undefined;"),
            "A Pi runtime without isIdle must report no flag instead of crashing the heartbeat."
        )
        XCTAssertTrue(
            probe.contains("} catch {") && probe.contains("return undefined;"),
            "A stale extension context throws, and a heartbeat must never propagate that."
        )
        XCTAssertTrue(
            probe.contains("=== true"),
            "Only an explicit idle answer may be reported as idle."
        )
    }

    func testIdlePiHeartbeatRepairsAStuckWorkingRow() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))
        let socket = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Hooks/HookSocketServer.swift"
        ))

        XCTAssertTrue(
            socket.contains("case isIdle = \"is_idle\""),
            "The wire payload's runtime idle flag must be decoded."
        )

        guard let recoveryStart = store.range(of: "private func recoverStuckPiWork(")?.lowerBound,
              let recoveryEnd = store.range(
                of: "private static func piCompletionBoundary(",
                range: recoveryStart..<store.endIndex
              )?.lowerBound else {
            return XCTFail("Stuck-Working recovery must live in one reviewable seam.")
        }
        let recovery = String(store[recoveryStart..<recoveryEnd])

        XCTAssertTrue(
            recovery.contains("PiIdleHeartbeatRecoveryPolicy.shouldResolveCompletionBoundary("),
            "A phase-neutral heartbeat must not pay for a filesystem probe."
        )
        XCTAssertTrue(recovery.contains("PiIdleHeartbeatRecoveryPolicy.outcome("))
        XCTAssertTrue(recovery.contains("reportedIdle: event.isIdle"))
        XCTAssertTrue(
            recovery.contains("currentPhaseIsActive: session.phase.isActive"),
            "Recovery applies to Working rows only: Processing and Compacting."
        )
        XCTAssertTrue(
            recovery.contains("case .ready: recovered = .waitingForInput")
                && recovery.contains("case .idle: recovered = .idle"),
            "The policy owns whether a repaired completion still publishes a Ready episode."
        )
        XCTAssertTrue(
            recovery.contains("guard session.phase.canTransition(to: recovered)"),
            "Recovery must respect the phase state machine."
        )
        XCTAssertTrue(
            recovery.contains("session.setPhase(recovered, evidenceSource: .hook, observedAt: now)"),
            "A recovered phase keeps hook evidence so the Ready staleness ceiling still applies."
        )
        XCTAssertTrue(
            recovery.contains("[Phase] pi"),
            "Recovery must be diagnosable from the discovery log."
        )

        XCTAssertTrue(
            store.contains("let didRecoverStuckWork = recoverStuckPiWork(")
                && store.contains("|| didRecoverStuckWork"),
            "The heartbeat branch must publish a repaired row."
        )
        guard let boundary = store.range(of: "private static func piCompletionBoundary(")?.lowerBound,
              let boundaryEnd = store.range(of: "\n    }", range: boundary..<store.endIndex)?.upperBound else {
            return XCTFail("The completion boundary resolver is missing.")
        }
        XCTAssertTrue(
            String(store[boundary..<boundaryEnd]).contains("if let path = event.sessionFile"),
            "Pi heartbeats carry the exact transcript path, which avoids a session-tree enumeration here."
        )
    }

    private func repoRoot(from fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent() // AgentVisorCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AgentVisorCore
            .deletingLastPathComponent() // repository root
    }
}
