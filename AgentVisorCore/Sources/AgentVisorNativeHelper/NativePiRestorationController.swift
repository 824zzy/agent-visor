import AgentVisorCore
import AppKit
import Darwin
import Foundation

/// Adapts bounded daemon lifecycle evidence to the existing Swift restoration modules.
@MainActor
final class NativePiRestorationController {
    private static let preflightInterval: TimeInterval = 11
    private static let topologyRefreshInterval: TimeInterval = 300

    private let currentBootID: String?
    private let snapshotStore: PiRestorationSnapshotStore
    private var coordinator: PiRebootRestorationCoordinator?
    private var disabled = false
    private var exactLiveSessionIDs: Set<String> = []
    private var removedCandidateSessionIDs: Set<String> = []
    private var ttyBySessionID: [String: String] = [:]
    private var topologyCaptureInFlight: Set<String> = []
    private var lastTopologyCaptureAt: [String: Date] = [:]
    private var powerOffObserver: NSObjectProtocol?

    init(dataRoot: URL = NativePiRestorationController.defaultDataRoot()) {
        currentBootID = MacBootIdentity.current()
        snapshotStore = PiRestorationSnapshotStore(
            fileURL: dataRoot.appendingPathComponent("pi-reboot-restoration.json")
        )

        guard let currentBootID else {
            disabled = true
            try? snapshotStore.remove()
            return
        }

        do {
            if let snapshot = try snapshotStore.load() {
                coordinator = PiRebootRestorationCoordinator(snapshot: snapshot)
            } else {
                try authorizeFreshCoordinator(bootID: currentBootID)
            }
        } catch {
            do {
                try authorizeFreshCoordinator(bootID: currentBootID)
            } catch {
                disabled = true
                coordinator = nil
            }
        }

        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.freezeForSystemPowerOff() }
        }

        Task { [weak self] in
            await self?.restorePriorBootIfNeeded()
        }
    }

    deinit {
        if let powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver)
        }
    }

    func reconcile(_ update: NativeHelperPiRestorationUpdate) {
        guard !disabled, var coordinator else { return }

        exactLiveSessionIDs = Set(update.liveSessionIds)
        removedCandidateSessionIDs.subtract(update.candidates.map(\.sessionId))
        removedCandidateSessionIDs.formUnion(update.removeCandidateSessionIds)

        if update.cleanTermination {
            coordinator.invalidateForCleanAppTermination()
            self.coordinator = coordinator
            persistSnapshot()
            return
        }

        var changed = false
        for candidate in update.candidates where exactLiveSessionIDs.contains(candidate.sessionId) {
            guard Self.isValid(candidate) else { continue }
            let existing = coordinator.snapshot.sessionsByID[candidate.sessionId]
            let session = PiRestorableSession(
                sessionId: candidate.sessionId,
                sessionFile: candidate.sessionFile,
                cwd: candidate.cwd,
                sessionName: candidate.sessionName,
                layout: existing?.layout,
                observedAt: existing?.observedAt ?? Date()
            )
            if existing != session {
                coordinator.observe(session)
                changed = true
            }

            let ttyChanged = ttyBySessionID[candidate.sessionId] != candidate.tty
            ttyBySessionID[candidate.sessionId] = candidate.tty
            let topologyIsStale = Date().timeIntervalSince(
                lastTopologyCaptureAt[candidate.sessionId] ?? .distantPast
            ) >= Self.topologyRefreshInterval
            if session.layout == nil || ttyChanged || topologyIsStale {
                captureTopologyIfNeeded(
                    sessionID: candidate.sessionId,
                    tty: candidate.tty,
                    cwd: candidate.cwd
                )
            }
        }

        for sessionID in update.removeCandidateSessionIds {
            if coordinator.snapshot.sessionsByID[sessionID] != nil {
                coordinator.end(sessionID: sessionID)
                changed = true
            }
            ttyBySessionID.removeValue(forKey: sessionID)
            topologyCaptureInFlight.remove(sessionID)
            lastTopologyCaptureAt.removeValue(forKey: sessionID)
        }

        self.coordinator = coordinator
        if changed { persistSnapshot() }
    }

    private func authorizeFreshCoordinator(bootID: String) throws {
        let fresh = PiRebootRestorationCoordinator(
            bootID: bootID,
            generationID: UUID().uuidString
        )
        var startup = PiRestorationStartupState(
            coordinator: fresh,
            needsInitialSnapshotPersistence: true
        )
        try startup.persistInitialSnapshotIfNeeded { snapshot in
            try snapshotStore.save(snapshot)
        }
        coordinator = startup.coordinator
    }

    private func authorizeFreshCoordinatorForRun(bootID: String) -> Bool {
        do {
            try authorizeFreshCoordinator(bootID: bootID)
            return true
        } catch {
            disabled = true
            coordinator = nil
            return false
        }
    }

    private func restorePriorBootIfNeeded() async {
        guard !disabled, let currentBootID, let startupCoordinator = coordinator else { return }
        let isPriorGeneration = startupCoordinator.snapshot.bootID != currentBootID
            && (startupCoordinator.snapshot.state == .active
                || startupCoordinator.snapshot.state == .frozen)
        if isPriorGeneration {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.preflightInterval * 1_000_000_000)
            )
        }

        guard var coordinator = self.coordinator else { return }
        var plan = coordinator.claimRestorePlan(
            currentBootID: currentBootID,
            liveSessionIDs: exactLiveSessionIDs.union(removedCandidateSessionIDs)
        ).filter(Self.isValid)
        self.coordinator = coordinator

        if coordinator.snapshot.state == .claimed {
            do {
                try snapshotStore.save(coordinator.snapshot)
            } catch {
                return
            }
            guard authorizeFreshCoordinatorForRun(bootID: currentBootID) else { return }
        } else if coordinator.snapshot.bootID != currentBootID
                    || coordinator.snapshot.state != .active {
            guard authorizeFreshCoordinatorForRun(bootID: currentBootID) else { return }
        }

        guard !plan.isEmpty, let piExecutable = Self.resolvePiExecutable() else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        plan.removeAll {
            exactLiveSessionIDs.contains($0.sessionId)
                || removedCandidateSessionIDs.contains($0.sessionId)
        }
        guard !plan.isEmpty else { return }

        let existingScript = PiGhosttyExistingSurfaceScript.make(
            sessions: plan,
            piExecutable: piExecutable
        )
        let existingOutput = existingScript.isEmpty
            ? ""
            : await Task.detached(priority: .utility) {
                Self.runAppleScriptForOutput(existingScript)
            }.value
        let reusedIDs = Set(PiGhosttyExistingSurfaceScript.restoredSessionIDs(
            from: existingOutput,
            candidates: Set(plan.map(\.sessionId))
        ))
        let fallbackPlan = plan.filter { !reusedIDs.contains($0.sessionId) }
        let fallbackScript = PiGhosttyRestorationScript.make(
            sessions: fallbackPlan,
            piExecutable: piExecutable
        )
        if !fallbackScript.isEmpty {
            _ = await Task.detached(priority: .utility) {
                Self.runAppleScript(fallbackScript)
            }.value
        }
    }

    private func freezeForSystemPowerOff() {
        guard !disabled, var coordinator else { return }
        coordinator.freezeForSystemPowerOff(at: Date())
        self.coordinator = coordinator
        persistSnapshot()
    }

    private func captureTopologyIfNeeded(sessionID: String, tty: String, cwd: String) {
        guard !topologyCaptureInFlight.contains(sessionID) else { return }
        topologyCaptureInFlight.insert(sessionID)
        lastTopologyCaptureAt[sessionID] = Date()

        Task { [weak self] in
            let layout = await Task.detached(priority: .utility) {
                Self.captureTopology(tty: tty, originalCwd: cwd)
            }.value
            guard let self else { return }
            topologyCaptureInFlight.remove(sessionID)
            guard ttyBySessionID[sessionID] == tty,
                  let layout,
                  !disabled,
                  var coordinator else { return }
            coordinator.updateLayout(sessionID: sessionID, layout: layout)
            self.coordinator = coordinator
            persistSnapshot()
        }
    }

    private func persistSnapshot() {
        guard !disabled, let coordinator else { return }
        try? snapshotStore.save(coordinator.snapshot)
    }

    private static func isValid(_ candidate: NativeHelperPiRestorationCandidate) -> Bool {
        var isDirectory: ObjCBool = false
        return PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: candidate.sessionFile)
            && FileManager.default.fileExists(atPath: candidate.cwd, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isValid(_ session: PiRestorableSession) -> Bool {
        var isDirectory: ObjCBool = false
        return PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: session.sessionFile)
            && FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private nonisolated static func captureTopology(
        tty: String,
        originalCwd: String
    ) -> PiGhosttyLayout? {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let marker = GhosttyMarkerLocator.makeMarker()
        guard write(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath) else {
            return nil
        }
        defer { _ = write(GhosttyMarkerLocator.osc7Sequence(cwd: originalCwd), to: ttyPath) }
        usleep(100_000)
        return GhosttyMarkerLocator.parseTopologyOutput(
            runAppleScriptForOutput(GhosttyMarkerLocator.topologyScript(marker: marker))
        )
    }

    private nonisolated static func write(_ text: String, to path: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path),
              let data = text.data(using: .utf8) else { return false }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    private nonisolated static func runAppleScript(_ source: String) -> Bool {
        runAppleScriptProcess(source, captureOutput: false)?.status == 0
    }

    private nonisolated static func runAppleScriptForOutput(_ source: String) -> String {
        guard let result = runAppleScriptProcess(source, captureOutput: true),
              result.status == 0 else { return "" }
        return String(data: result.output, encoding: .utf8) ?? ""
    }

    private nonisolated static func runAppleScriptProcess(
        _ source: String,
        captureOutput: Bool
    ) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = captureOutput ? Pipe() : nil
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        let wait = finished.wait(timeout: .now() + SubprocessDeadlinePolicy.appCommand)
        guard wait == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            try? output?.fileHandleForReading.close()
            return nil
        }
        let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return (process.terminationStatus, data)
    }

    private nonisolated static func resolvePiExecutable() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            home + "/.local/bin/pi",
        ]
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            candidates.append(contentsOf: versions.sorted().reversed().map {
                nvmRoot + "/" + $0 + "/bin/pi"
            })
        }
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    private nonisolated static func defaultDataRoot() -> URL {
        if let value = ProcessInfo.processInfo.environment["AGENT_VISOR_DATA_DIR"],
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agent Visor Next", isDirectory: true)
    }
}
