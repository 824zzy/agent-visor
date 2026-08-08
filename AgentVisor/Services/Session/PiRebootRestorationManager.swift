import AgentVisorCore
import AppKit
import Foundation
import os.log

/// Persists the exact set of accepted interactive Pi runtimes owned by
/// Ghostty and restores one prior-boot generation at most once.
@MainActor
final class PiRebootRestorationManager {
    static let shared = PiRebootRestorationManager()

    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "PiRebootRestore"
    )
    private static let snapshotFileName = "pi-reboot-restoration.json"
    /// Pi heartbeats run every 10 seconds. Waiting one complete interval plus
    /// scheduling slack lets an already-running exact owner report before a
    /// prior-boot generation is claimed.
    private static let priorBootPreflightInterval: TimeInterval = 11

    private let currentBootID: String?
    private let snapshotStore: PiRestorationSnapshotStore
    private var coordinator: PiRebootRestorationCoordinator?
    private var started = false
    private var disabled = false
    private var needsInitialSnapshotPersistence = false
    private var topologyCaptureInFlight: Set<String> = []
    private var ttyBySessionID: [String: String] = [:]
    private var lastTopologyCaptureAt: [String: Date] = [:]
    private var exactLiveSessionIDs: Set<String> = []
    private let topologyRefreshInterval: TimeInterval = 300

    private init() {
        currentBootID = MacBootIdentity.current()
        let fileURL = AppPaths.appSupportDirectory()
            .appendingPathComponent(Self.snapshotFileName)
        snapshotStore = PiRestorationSnapshotStore(fileURL: fileURL)
        coordinator = nil
        guard let currentBootID else { return }
        do {
            if let persisted = try snapshotStore.load() {
                coordinator = PiRebootRestorationCoordinator(snapshot: persisted)
            } else {
                coordinator = PiRebootRestorationCoordinator(
                    bootID: currentBootID,
                    generationID: UUID().uuidString
                )
                needsInitialSnapshotPersistence = true
            }
        } catch {
            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
            needsInitialSnapshotPersistence = true
            Self.logger.error("Could not load or sanitize Pi restoration snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(liveSessionIDs: Set<String> = []) async {
        guard !started else { return }
        started = true
        guard let currentBootID else {
            disabled = true
            coordinator = nil
            Self.logger.error("Skipping Pi reboot restoration: macOS boot identity unavailable")
            do {
                try snapshotStore.remove()
            } catch {
                Self.logger.error("Could not remove Pi restoration snapshot after boot identity failure: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard var coordinator else {
            disabled = true
            Self.logger.error("Skipping Pi reboot restoration: coordinator unavailable")
            return
        }

        if needsInitialSnapshotPersistence {
            var startupState = PiRestorationStartupState(
                coordinator: coordinator,
                needsInitialSnapshotPersistence: true
            )
            do {
                try startupState.persistInitialSnapshotIfNeeded { snapshot in
                    try snapshotStore.save(snapshot)
                }
            } catch {
                disabled = true
                self.coordinator = nil
                needsInitialSnapshotPersistence =
                    startupState.needsInitialSnapshotPersistence
                Self.logger.error("Could not persist initial Pi restoration baseline; restoration is disabled for this run: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let authorizedCoordinator = startupState.coordinator else {
                disabled = true
                self.coordinator = nil
                Self.logger.error("Could not authorize initial Pi restoration baseline; restoration is disabled for this run")
                return
            }
            coordinator = authorizedCoordinator
            self.coordinator = authorizedCoordinator
            needsInitialSnapshotPersistence =
                startupState.needsInitialSnapshotPersistence
        }

        if coordinator.snapshot.schemaVersion != PiRestorationSnapshot.currentSchemaVersion {
            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
            self.coordinator = coordinator
            persistSnapshot()
        }

        let canClaimPriorBootGeneration = coordinator.snapshot.bootID != currentBootID
            && (coordinator.snapshot.state == .active || coordinator.snapshot.state == .frozen)
        if canClaimPriorBootGeneration {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.priorBootPreflightInterval * 1_000_000_000)
            )
        }

        var plan = coordinator.claimRestorePlan(
            currentBootID: currentBootID,
            liveSessionIDs: liveSessionIDs.union(exactLiveSessionIDs)
        ).filter(Self.isValidRestoreCandidate)
        self.coordinator = coordinator

        if coordinator.snapshot.state == .claimed {
            do {
                // Claim must reach disk before any command is sent. If the app
                // exits during AppleScript, a same-boot relaunch sees the new
                // active generation below and will not duplicate an attempt.
                try snapshotStore.save(coordinator.snapshot)
            } catch {
                Self.logger.error("Could not persist claimed Pi restore generation: \(error.localizedDescription, privacy: .public)")
                return
            }

            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
            self.coordinator = coordinator
            persistSnapshot()
        } else if coordinator.snapshot.bootID != currentBootID
                    || coordinator.snapshot.state != .active {
            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
            self.coordinator = coordinator
            persistSnapshot()
        }

        guard !plan.isEmpty else { return }
        guard let piExecutable = Self.resolvePiExecutable() else {
            Self.logger.error("Skipping Pi reboot restoration: executable not found")
            return
        }

        Self.logger.notice("Restoring \(plan.count, privacy: .public) exact Pi session(s) from prior boot")

        // Give Ghostty's AppKit saved-state restoration a bounded chance to
        // recreate prior windows/tabs. Matching positions are reused only
        // when their working directory still agrees; everything else falls
        // back to newly created, deterministic surfaces.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        // Close the final race between the preflight claim and automation. A
        // late exact heartbeat still prevents input or a fallback window even
        // though the generation was already durably claimed at most once.
        plan.removeAll { exactLiveSessionIDs.contains($0.sessionId) }
        guard !plan.isEmpty else {
            Self.logger.notice("Skipping prior-boot Pi launches: every candidate already has an exact live owner")
            return
        }
        let existingScript = PiGhosttyExistingSurfaceScript.make(
            sessions: plan,
            piExecutable: piExecutable
        )
        let existingOutput: String
        if existingScript.isEmpty {
            existingOutput = ""
        } else {
            existingOutput = await Task.detached(priority: .utility) {
                Self.runAppleScriptForOutput(existingScript)
            }.value
        }
        let reusedIDs = Set(PiGhosttyExistingSurfaceScript.restoredSessionIDs(
            from: existingOutput,
            candidates: Set(plan.map(\.sessionId))
        ))
        let fallbackPlan = plan.filter { !reusedIDs.contains($0.sessionId) }
        let script = PiGhosttyRestorationScript.make(
            sessions: fallbackPlan,
            piExecutable: piExecutable
        )
        let fallbackSucceeded: Bool
        if script.isEmpty {
            fallbackSucceeded = true
        } else {
            fallbackSucceeded = await Task.detached(priority: .utility) {
                Self.runAppleScript(script)
            }.value
        }

        if fallbackSucceeded {
            Self.logger.notice("Dispatched prior-boot Pi restoration generation; reused=\(reusedIDs.count, privacy: .public) fallback=\(fallbackPlan.count, privacy: .public)")
        } else {
            Self.logger.error("Ghostty rejected or failed the Pi fallback restoration script")
        }
    }

    func noteExactLiveSession(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        exactLiveSessionIDs.insert(sessionID)
    }

    func noteExactSessionEnded(sessionID: String) {
        exactLiveSessionIDs.remove(sessionID)
    }

    func recordAcceptedSession(
        sessionID: String,
        sessionFile: String,
        cwd: String,
        sessionName: String?,
        tty: String,
        allowTopologyRefresh: Bool
    ) {
        noteExactLiveSession(sessionID: sessionID)
        guard started,
              !disabled,
              var coordinator,
              !sessionID.isEmpty else { return }

        guard PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile) else {
            removeRestorationCandidate(sessionID: sessionID)
            return
        }

        guard !sessionFile.isEmpty,
              !cwd.isEmpty,
              !tty.isEmpty else { return }

        let existing = coordinator.snapshot.sessionsByID[sessionID]
        let session = PiRestorableSession(
            sessionId: sessionID,
            sessionFile: sessionFile,
            cwd: cwd,
            sessionName: sessionName,
            layout: existing?.layout,
            observedAt: existing?.observedAt ?? Date()
        )
        if existing != session {
            coordinator.observe(session)
            self.coordinator = coordinator
            persistSnapshot()
        }

        let ttyChanged = ttyBySessionID[sessionID] != tty
        ttyBySessionID[sessionID] = tty
        let topologyIsStale = allowTopologyRefresh
            && Date().timeIntervalSince(lastTopologyCaptureAt[sessionID] ?? .distantPast)
                >= topologyRefreshInterval
        if session.layout == nil || ttyChanged || topologyIsStale {
            captureTopologyIfNeeded(sessionID: sessionID, tty: tty, cwd: cwd)
        }
    }

    /// Removes reboot-restoration eligibility without claiming that the live
    /// runtime ended. A Pi session hosted by iTerm, Zed, or another non-Ghostty
    /// owner must still block a duplicate prior-boot launch of the same durable
    /// session ID.
    func removeRestorationCandidate(sessionID: String) {
        guard started, !disabled, var coordinator else { return }
        let existed = coordinator.snapshot.sessionsByID[sessionID] != nil
        coordinator.end(sessionID: sessionID)
        self.coordinator = coordinator
        ttyBySessionID.removeValue(forKey: sessionID)
        topologyCaptureInFlight.remove(sessionID)
        lastTopologyCaptureAt.removeValue(forKey: sessionID)
        if existed && coordinator.snapshot.sessionsByID[sessionID] == nil {
            persistSnapshot()
        }
    }

    func end(sessionID: String) {
        noteExactSessionEnded(sessionID: sessionID)
        removeRestorationCandidate(sessionID: sessionID)
    }

    func freezeForSystemPowerOff() {
        guard started, !disabled, var coordinator else { return }
        coordinator.freezeForSystemPowerOff(at: Date())
        self.coordinator = coordinator
        persistSnapshot()
    }

    func invalidateForCleanAppTermination() {
        guard started, !disabled, var coordinator else { return }
        coordinator.invalidateForCleanAppTermination()
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
            self.topologyCaptureInFlight.remove(sessionID)
            guard self.ttyBySessionID[sessionID] == tty,
                  let layout,
                  self.started,
                  !self.disabled,
                  var coordinator = self.coordinator else { return }
            coordinator.updateLayout(sessionID: sessionID, layout: layout)
            self.coordinator = coordinator
            self.persistSnapshot()
        }
    }

    private func persistSnapshot() {
        guard !disabled, let coordinator else { return }
        do {
            try snapshotStore.save(coordinator.snapshot)
        } catch {
            Self.logger.error("Could not persist Pi restoration snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isValidRestoreCandidate(_ session: PiRestorableSession) -> Bool {
        var isDirectory: ObjCBool = false
        guard PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: session.sessionFile),
              FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return true
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
        defer {
            _ = write(GhosttyMarkerLocator.osc7Sequence(cwd: originalCwd), to: ttyPath)
        }
        usleep(100_000)
        let output = runAppleScriptForOutput(
            GhosttyMarkerLocator.topologyScript(marker: marker)
        )
        return GhosttyMarkerLocator.parseTopologyOutput(output)
    }

    private nonisolated static func write(_ text: String, to path: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path),
              let data = text.data(using: .utf8) else { return false }
        handle.write(data)
        handle.closeFile()
        return true
    }

    private nonisolated static func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated static func runAppleScriptForOutput(_ source: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private nonisolated static func resolvePiExecutable() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            home + "/.local/bin/pi",
        ]
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            candidates.append(contentsOf: versions.sorted().reversed().map {
                nvmRoot + "/" + $0 + "/bin/pi"
            })
        }
        return candidates.first(where: fm.isExecutableFile(atPath:))
    }

}
