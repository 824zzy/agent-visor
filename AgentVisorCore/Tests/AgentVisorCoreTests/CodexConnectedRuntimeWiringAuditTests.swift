import XCTest

final class CodexConnectedRuntimeWiringAuditTests: XCTestCase {
    func testConnectedCodexUsesZeroInterruptionUnixRuntimePath() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexConnectedRuntimeCoordinator.swift"
            )
        )
        let client = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedAppServerClient.swift"
            )
        )
        let settings = try source(
            at: root.appendingPathComponent(
                "AgentVisor/UI/Window/SettingsWindowView.swift"
            )
        )
        let activePath = coordinator + client + settings

        XCTAssertTrue(
            coordinator.contains("CodexConnectionReconciler.reconcile"),
            "Connected Codex lifecycle changes must flow through the tested zero-interruption reconciler."
        )
        XCTAssertTrue(
            coordinator.contains("CodexProcessRPCTransportFactory"),
            "Agent Visor must connect to the shared Unix broker through the process proxy transport."
        )
        XCTAssertFalse(
            activePath.contains("CODEX_APP_SERVER_WS_URL"),
            "The active Connected Codex path must not use the obsolete TCP/WebSocket environment contract."
        )
        XCTAssertFalse(
            activePath.contains("terminateCodexDesktop"),
            "Enabling or disabling Connected Codex must never terminate Codex Desktop."
        )
        XCTAssertFalse(
            activePath.contains("Relaunch Codex"),
            "Connected Codex must wait for the next natural Codex launch instead of asking for a relaunch."
        )
    }

    func testUnregisteredBackgroundAgentCanEnterRegistrationFlow() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let manager = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedRuntimeServiceManager.swift"
            )
        )

        XCTAssertTrue(
            manager.contains("case .notRegistered, .notFound:"),
            "SMAppService reports notFound before first registration; the adapter must normalize it to notRegistered."
        )
    }

    func testProxyAndRPCIngressUseSingleOrderedConsumers() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let transport = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexProcessRPCTransport.swift"
            )
        )
        let session = try source(
            at: root.appendingPathComponent(
                "AgentVisorCore/Sources/AgentVisorCore/CodexRPCSession.swift"
            )
        )

        XCTAssertTrue(transport.contains("AsyncStream<OutputEvent>"))
        XCTAssertTrue(session.contains("AsyncStream<InboundEvent>"))
        XCTAssertFalse(
            transport.contains("Task {\n                if data.isEmpty"),
            "Each stdout callback must enqueue into one consumer instead of spawning a competing task."
        )
        XCTAssertFalse(
            session.contains("Task { await self?.receive(message) }"),
            "Decoded RPC messages must preserve transport order."
        )
    }

    func testDesktopProbeRunsBlockingProcessInspectionOffMainActor() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let probe = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedRuntimeDesktopProbe.swift"
            )
        )

        XCTAssertTrue(probe.contains("Task.detached"))
        XCTAssertTrue(probe.contains("CodexSharedRuntimeSocketPolicy.hasConnection"))
    }

    func testDesktopProbePreservesPartialLsofOutput() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let probe = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedRuntimeDesktopProbe.swift"
            )
        )
        let executor = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Shared/ProcessExecutor.swift"
            )
        )

        XCTAssertTrue(executor.contains("runSyncWithResult"))
        XCTAssertTrue(probe.contains("ProcessOutputSnapshot"))
        XCTAssertTrue(probe.contains("runSyncWithResult"))
    }

    func testApprovalBridgeDoesNotOverwriteAnUnresolvedRequest() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let bridge = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexAppServerApprovalBridge.swift"
            )
        )

        XCTAssertTrue(bridge.contains("guard pendingByThread[threadId] == nil else"))
    }

    func testConnectedTransportLossClearsOrphanedPendingRequests() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let coordinator = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexConnectedRuntimeCoordinator.swift"
            )
        )
        let bridge = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexAppServerApprovalBridge.swift"
            )
        )

        XCTAssertTrue(bridge.contains("func connectedTransportDisconnected()"))
        XCTAssertGreaterThanOrEqual(
            coordinator.components(separatedBy: "connectedTransportDisconnected()").count - 1,
            2
        )
    }

    func testRuntimeHealthProcessIsBoundedAndRunsOffCallingActor() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let health = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedRuntimeHealthChecker.swift"
            )
        )
        let executor = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Shared/ProcessExecutor.swift"
            )
        )

        XCTAssertTrue(health.contains("timeout: 5"))
        XCTAssertTrue(executor.contains("case timedOut(command: String)"))
        XCTAssertTrue(executor.contains("DispatchQueue.global(qos: .utility).async"))
    }

    func testSharedClientRetriesDocumentedOverloadResponse() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let client = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexSharedAppServerClient.swift"
            )
        )

        XCTAssertTrue(client.contains("requestWithOverloadRetry"))
        XCTAssertTrue(client.contains("CodexRPCOverloadRetryPolicy.delayNanoseconds"))
    }

    func testProxyWritesAreBoundedOutsideTransportActor() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let transport = try source(
            at: root.appendingPathComponent(
                "AgentVisor/Services/Agents/CodexProcessRPCTransport.swift"
            )
        )

        XCTAssertTrue(transport.contains("nonisolated private final class CodexPipeWriter"))
        XCTAssertTrue(transport.contains("try await writer.write"))
        XCTAssertTrue(transport.contains("case timedOut"))
    }

    func testDevBuildVerifiesEmbeddedRuntimeLayoutAndSignature() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let devBuild = try source(
            at: root.appendingPathComponent("scripts/dev-build.sh")
        )
        let verifier = try source(
            at: root.appendingPathComponent("scripts/test-codex-runtime-bundle.sh")
        )

        XCTAssertTrue(devBuild.contains("test-codex-runtime-bundle.sh"))
        XCTAssertTrue(verifier.contains("Contents/Helpers/AgentVisorCodexRuntime"))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("com.824zzy.AgentVisor.CodexRuntime"))
    }

    func testReleaseBuildOmitsExperimentalRuntimeBundle() throws {
        let root = repoRoot(from: URL(fileURLWithPath: #filePath))
        let project = try source(
            at: root.appendingPathComponent("AgentVisor.xcodeproj/project.pbxproj")
        )

        XCTAssertTrue(
            project.contains("dstPath = \"$(AV_CODEX_RUNTIME_HELPER_DESTINATION)\";")
        )
        XCTAssertTrue(
            project.contains("dstPath = \"$(AV_CODEX_RUNTIME_LAUNCH_AGENT_DESTINATION)\";")
        )
        XCTAssertTrue(
            project.contains(
                "AV_CODEX_RUNTIME_HELPER_DESTINATION = \"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers\";"
            ),
            "Debug builds must keep embedding the helper for Connected Codex development."
        )
        XCTAssertTrue(
            project.contains(
                "AV_CODEX_RUNTIME_LAUNCH_AGENT_DESTINATION = \"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents\";"
            )
        )
        XCTAssertTrue(
            project.contains(
                "AV_CODEX_RUNTIME_HELPER_DESTINATION = \"$(TARGET_TEMP_DIR)/ExperimentalCodexRuntime/Helpers\";"
            ),
            "Release builds must keep the experimental helper outside the distributed app bundle."
        )
        XCTAssertTrue(
            project.contains(
                "AV_CODEX_RUNTIME_LAUNCH_AGENT_DESTINATION = \"$(TARGET_TEMP_DIR)/ExperimentalCodexRuntime/LaunchAgents\";"
            )
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url)
    }

    private func repoRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
