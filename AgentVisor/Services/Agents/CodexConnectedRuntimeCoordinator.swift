import AppKit
import Combine
import AgentVisorCore
import Foundation
import ServiceManagement
import os.log

@MainActor
final class CodexConnectedRuntimeCoordinator: ObservableObject {
    enum CoordinatorError: Error, LocalizedError {
        case threadNotConnected

        var errorDescription: String? {
            switch self {
            case .threadNotConnected:
                return "This Codex thread is not connected to the shared runtime."
            }
        }
    }

    private struct ServiceObservation {
        let state: CodexSharedRuntimeServiceState
        let isHealthy: Bool
    }

    static let shared = CodexConnectedRuntimeCoordinator()
    nonisolated private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "CodexConnected"
    )

    @Published private(set) var state: CodexConnectionLifecycle {
        didSet {
            guard state != oldValue else { return }
            Self.logger.info(
                "lifecycle \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)"
            )
        }
    }
    @Published private(set) var isEnabled: Bool

    private let serviceManager: any CodexSharedRuntimeServiceManaging
    private let environmentManager: any CodexSharedRuntimeEnvironmentManaging
    private let healthChecker: any CodexSharedRuntimeHealthChecking
    private let desktopProbe: any CodexDesktopRuntimeProbing
    private let transportFactory: any CodexProcessRPCTransportBuilding
    private let launchPlan: CodexSharedRuntimeLaunchPlan

    private var activationDate: Date?
    private var client: CodexSharedAppServerClient?
    private var clientGeneration: UUID?
    private var agentVisorClientConnected = false
    private var desiredThreadIds = Set<String>()
    private var attachedThreadIds = Set<String>()

    private var started = false
    private var shuttingDown = false
    private var reconciliationInProgress = false
    private var reconciliationRequested = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var periodicTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var nextReconnectDate: Date?

    private init() {
        let plan = CodexSharedRuntimeLaunchPlan(codexHome: Self.codexHomePath())
        serviceManager = CodexSharedRuntimeServiceManager()
        environmentManager = CodexSharedRuntimeEnvironmentManager()
        healthChecker = CodexSharedRuntimeHealthChecker()
        desktopProbe = CodexSharedRuntimeDesktopProbe(
            sharedRuntimeSocketPath: plan.socketPath
        )
        transportFactory = CodexProcessRPCTransportFactory()
        launchPlan = plan

        let persistedEnabled = AppSettings.connectedCodexEnabled
        if !AppSettings.hasConnectedCodexLaunchEnvironmentOwnershipRecord {
            AppSettings.connectedCodexLaunchEnvironmentOwned = persistedEnabled
                && AppSettings.connectedCodexActivationDate != nil
        }
        isEnabled = persistedEnabled
        state = persistedEnabled ? .preparing : .off
        activationDate = AppSettings.connectedCodexActivationDate
    }

    var isRunning: Bool {
        state == .connected
    }

    var statusText: String {
        switch state {
        case .off:
            return "Off"
        case .preparing:
            return "Preparing shared runtime..."
        case .requiresBackgroundApproval:
            return "Background approval required"
        case .waitingForNextCodexLaunch:
            return "Connects next time Codex opens"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting..."
        case .disconnectPending:
            return "Disconnect pending until Codex exits"
        case .failedObserved(let message):
            return "Observed only: \(message)"
        }
    }

    func resumePersistedIntent() async {
        guard !started else {
            await reconcile()
            return
        }
        started = true
        shuttingDown = false
        isEnabled = AppSettings.connectedCodexEnabled
        activationDate = AppSettings.connectedCodexActivationDate
        if isEnabled, activationDate == nil {
            let date = Date()
            activationDate = date
            AppSettings.connectedCodexActivationDate = date
        }
        if isEnabled {
            installWorkspaceObservers()
            startPeriodicReconciliation()
        }
        await reconcile()
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled, !isEnabled {
            let date = Date()
            activationDate = date
            AppSettings.connectedCodexActivationDate = date
            state = .preparing
        }
        if !enabled {
            desiredThreadIds.removeAll()
        }

        isEnabled = enabled
        AppSettings.connectedCodexEnabled = enabled
        resetReconnectBackoff()
        if enabled {
            installWorkspaceObservers()
            startPeriodicReconciliation()
        }
        await reconcile()
    }

    func startLab() async {
        await setEnabled(true)
    }

    func stopLab() async {
        await setEnabled(false)
    }

    func refresh() async {
        resetReconnectBackoff()
        if isEnabled {
            installWorkspaceObservers()
            startPeriodicReconciliation()
        }
        await reconcile()
    }

    func openBackgroundItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func shutdownForAppTermination() async {
        shuttingDown = true
        periodicTask?.cancel()
        periodicTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()

        await disconnectAgentVisorClient(clearDesiredThreads: false)
        started = false
    }

    func attachIfLabActive(threadId: String) async {
        guard isRunning,
              let session = await SessionStore.shared.session(for: threadId),
              session.agentID == .codex,
              session.origin == .observed,
              session.tty == nil else { return }

        desiredThreadIds.insert(threadId)
        await attach(threadId: threadId)
    }

    func sendTurn(
        threadId: String,
        text: String,
        localImagePaths: [String]
    ) async throws {
        guard attachedThreadIds.contains(threadId), let client else {
            throw CoordinatorError.threadNotConnected
        }
        try await client.sendTurn(
            threadId: threadId,
            text: text,
            localImagePaths: localImagePaths
        )
    }

    func interrupt(threadId: String, turnId: String) async throws {
        guard attachedThreadIds.contains(threadId), let client else {
            throw CoordinatorError.threadNotConnected
        }
        try await client.interrupt(threadId: threadId, turnId: turnId)
    }

    func threadBecameUnavailable(threadId: String) async {
        desiredThreadIds.remove(threadId)
        guard attachedThreadIds.remove(threadId) != nil else { return }
        await SessionStore.shared.setCodexControlCapability(
            sessionId: threadId,
            capability: .observed
        )
    }

    func respond(id: CodexRPCID, result: [String: AnyCodable]) async {
        try? await client?.respond(id: id, result: result)
    }

    func respondError(id: CodexRPCID, message: String) async {
        try? await client?.respondError(id: id, message: message)
    }

    private func reconcile() async {
        guard !shuttingDown else { return }
        if reconciliationInProgress {
            reconciliationRequested = true
            return
        }

        reconciliationInProgress = true
        repeat {
            reconciliationRequested = false
            await performReconciliation()
        } while reconciliationRequested && !shuttingDown
        reconciliationInProgress = false
        updateRuntimeObservation()
    }

    private func performReconciliation() async {
        for _ in 0..<6 where !shuttingDown {
            let service = await observeService()

            if isEnabled, service.isHealthy {
                _ = await ensureAgentVisorClientConnected()
            }

            let futureLaunchesArmed = (try? await environmentManager.currentValue()) == "1"
            if !futureLaunchesArmed, AppSettings.connectedCodexLaunchEnvironmentOwned {
                AppSettings.connectedCodexLaunchEnvironmentOwned = false
            }
            let desktop = await desktopProbe.probe(
                activationDate: activationDate,
                sharedRuntimeHealthy: service.isHealthy,
                agentVisorHandshake: agentVisorClientConnected
            )
            let reconciliation = CodexConnectionReconciler.reconcile(
                CodexConnectionSnapshot(
                    isEnabled: isEnabled,
                    lifecycle: state,
                    serviceState: service.state,
                    desktopRuntime: desktop.runtime,
                    futureLaunchesArmed: futureLaunchesArmed,
                    futureLaunchesOwned: AppSettings.connectedCodexLaunchEnvironmentOwned,
                    agentVisorClientConnected: agentVisorClientConnected
                )
            )
            let previousState = state
            state = reconciliation.lifecycle
            if previousState == .connected, state != .connected {
                attachedThreadIds.removeAll()
                await SessionStore.shared.resetConnectedCodexControlCapabilities()
            }

            do {
                for action in reconciliation.actions {
                    try await perform(action)
                }
            } catch {
                state = .failedObserved(message: error.localizedDescription)
                Self.logger.error(
                    "runtime reconciliation failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }

            if !isEnabled {
                await disconnectAgentVisorClient(clearDesiredThreads: true)
            }

            guard !reconciliation.actions.isEmpty else {
                if state == .connected {
                    await reattachDesiredThreads()
                }
                if state == .off {
                    activationDate = nil
                    AppSettings.connectedCodexActivationDate = nil
                    stopRuntimeObservation()
                }
                return
            }
        }
    }

    private func observeService() async -> ServiceObservation {
        let attempts = state == .preparing ? 20 : 1
        var lastMessage = "Shared Codex runtime did not become healthy."

        for attempt in 0..<attempts {
            switch serviceManager.status {
            case .notRegistered:
                return ServiceObservation(state: .notRegistered, isHealthy: false)
            case .requiresApproval:
                return ServiceObservation(
                    state: .requiresBackgroundApproval,
                    isHealthy: false
                )
            case .enabled:
                do {
                    let health = try await healthChecker.check(
                        expectedSocketPath: launchPlan.socketPath
                    )
                    if health.isHealthy {
                        return ServiceObservation(state: .healthy, isHealthy: true)
                    }
                    lastMessage = Self.healthFailureMessage(health)
                } catch {
                    lastMessage = "Shared runtime health check failed: \(error.localizedDescription)"
                }
            }

            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        return ServiceObservation(
            state: .unhealthy(message: lastMessage),
            isHealthy: false
        )
    }

    private func perform(_ action: CodexConnectionAction) async throws {
        switch action {
        case .registerSharedRuntime:
            do {
                try serviceManager.register()
            } catch {
                switch serviceManager.status {
                case .enabled, .requiresApproval:
                    return
                case .notRegistered:
                    throw error
                }
            }
        case .armFutureDesktopLaunches:
            try await environmentManager.setEnabled()
            AppSettings.connectedCodexLaunchEnvironmentOwned = true
        case .disarmFutureDesktopLaunches:
            try await environmentManager.unset()
            AppSettings.connectedCodexLaunchEnvironmentOwned = false
        case .unregisterSharedRuntime:
            await disconnectAgentVisorClient(clearDesiredThreads: true)
            do {
                try serviceManager.unregister()
            } catch {
                switch serviceManager.status {
                case .notRegistered:
                    return
                case .enabled, .requiresApproval:
                    throw error
                }
            }
        }
    }

    private func ensureAgentVisorClientConnected() async -> Bool {
        if agentVisorClientConnected, client != nil {
            return true
        }
        if let nextReconnectDate, nextReconnectDate > Date() {
            return false
        }

        do {
            let session = try transportFactory.makeSession(launchPlan: launchPlan)
            let sharedClient = CodexSharedAppServerClient(rpcSession: session)
            let generation = UUID()
            await sharedClient.setHandlers(CodexAppServerHandlers(
                onNotification: { method, params in
                    await MainActor.run {
                        CodexAppServerStreamBridge.shared.handle(method: method, params: params)
                    }
                },
                onServerRequest: { id, method, params in
                    await MainActor.run {
                        CodexAppServerApprovalBridge.shared.handleConnected(
                            id: id,
                            method: method,
                            params: params
                        )
                    }
                },
                onClose: { [weak self] in
                    await self?.connectionLost(generation: generation)
                }
            ))

            client = sharedClient
            clientGeneration = generation
            do {
                try await sharedClient.connect(clientVersion: Self.appVersion())
            } catch {
                if clientGeneration == generation {
                    client = nil
                    clientGeneration = nil
                    agentVisorClientConnected = false
                }
                await sharedClient.close()
                throw error
            }

            guard clientGeneration == generation else {
                await sharedClient.close()
                return false
            }
            agentVisorClientConnected = true
            resetReconnectBackoff()
            Self.logger.info("connected to shared Codex Unix runtime")
            return true
        } catch {
            Self.logger.error(
                "shared runtime proxy connection failed: \(error.localizedDescription, privacy: .public)"
            )
            scheduleReconnect()
            return false
        }
    }

    private func connectionLost(generation: UUID) async {
        guard clientGeneration == generation, !shuttingDown else { return }
        CodexAppServerApprovalBridge.shared.connectedTransportDisconnected()
        client = nil
        clientGeneration = nil
        agentVisorClientConnected = false
        attachedThreadIds.removeAll()
        await SessionStore.shared.resetConnectedCodexControlCapabilities()

        if isEnabled {
            state = .reconnecting
            scheduleReconnect()
            await reconcile()
        }
    }

    private func disconnectAgentVisorClient(clearDesiredThreads: Bool) async {
        CodexAppServerApprovalBridge.shared.connectedTransportDisconnected()
        let connectedClient = client
        let hadConnectedState = connectedClient != nil
            || agentVisorClientConnected
            || !attachedThreadIds.isEmpty

        client = nil
        clientGeneration = nil
        agentVisorClientConnected = false
        attachedThreadIds.removeAll()
        if clearDesiredThreads {
            desiredThreadIds.removeAll()
        }

        if let connectedClient {
            await connectedClient.close()
        }
        if hadConnectedState {
            await SessionStore.shared.resetConnectedCodexControlCapabilities()
        }
    }

    private func attach(threadId: String) async {
        guard isRunning,
              !attachedThreadIds.contains(threadId),
              let client,
              let generation = clientGeneration else { return }

        do {
            let evidence = try await client.attach(threadId: threadId)
            guard clientGeneration == generation, state == .connected else { return }
            let capability = CodexControlCapabilityPolicy.capability(
                threadId: threadId,
                isAgentVisorManaged: false,
                sharedRuntimeEvidence: evidence
            )
            guard capability == .connected else { return }
            attachedThreadIds.insert(threadId)
            await SessionStore.shared.setCodexControlCapability(
                sessionId: threadId,
                capability: capability
            )
        } catch {
            Self.logger.error(
                "attach failed sid=\(threadId.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await SessionStore.shared.setCodexControlCapability(
                sessionId: threadId,
                capability: .observed
            )
        }
    }

    private func reattachDesiredThreads() async {
        for threadId in desiredThreadIds.sorted() where !attachedThreadIds.contains(threadId) {
            guard let session = await SessionStore.shared.session(for: threadId),
                  session.agentID == .codex,
                  session.origin == .observed,
                  session.tty == nil else {
                desiredThreadIds.remove(threadId)
                continue
            }
            await attach(threadId: threadId)
        }
    }

    private func scheduleReconnect() {
        guard isEnabled, !shuttingDown, reconnectTask == nil else { return }
        let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000]
        let index = min(reconnectAttempt, delays.count - 1)
        let delay = delays[index]
        reconnectAttempt = min(reconnectAttempt + 1, delays.count - 1)
        nextReconnectDate = Date().addingTimeInterval(Double(delay) / 1_000_000_000)

        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !self.shuttingDown else { return }
            self.reconnectTask = nil
            self.nextReconnectDate = nil
            await self.reconcile()
        }
    }

    private func resetReconnectBackoff() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        nextReconnectDate = nil
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      application.bundleIdentifier == "com.openai.codex" else { return }
                Task { @MainActor in
                    await self?.reconcile()
                }
            })
        }
    }

    private func startPeriodicReconciliation() {
        guard periodicTask == nil else { return }
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard let self, !self.shuttingDown else { return }
                await self.reconcile()
            }
        }
    }

    private func stopRuntimeObservation() {
        periodicTask?.cancel()
        periodicTask = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func updateRuntimeObservation() {
        guard !shuttingDown else { return }
        if CodexConnectionObservationPolicy.shouldObserve(
            isEnabled: isEnabled,
            lifecycle: state
        ) {
            installWorkspaceObservers()
            startPeriodicReconciliation()
        } else {
            stopRuntimeObservation()
        }
    }

    private static func healthFailureMessage(_ health: CodexSharedRuntimeHealth) -> String {
        if !health.statusRunning {
            return "Shared runtime status is \(health.daemonStatus)."
        }
        if !health.versionsCompatible {
            return "Codex runtime version does not match Codex Desktop."
        }
        if !health.socketPathMatches {
            return "Codex reported a different shared-runtime socket."
        }
        if !health.socketExists {
            return "Shared-runtime socket is missing."
        }
        return "Shared Codex runtime is unhealthy."
    }

    private static func codexHomePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let configured = Foundation.ProcessInfo.processInfo.environment["CODEX_HOME"],
              !configured.isEmpty else {
            return home.appendingPathComponent(".codex", isDirectory: true)
                .standardizedFileURL.path
        }

        let expanded = NSString(string: configured).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : home.appendingPathComponent(expanded, isDirectory: true)
        return url.standardizedFileURL.path
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
