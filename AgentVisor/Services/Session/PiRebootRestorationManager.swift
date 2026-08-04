import AgentVisorCore
import AppKit
import Darwin
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

    private let currentBootID: String
    private let snapshotStore: PiRestorationSnapshotStore
    private var coordinator: PiRebootRestorationCoordinator
    private var started = false
    private var topologyCaptureInFlight: Set<String> = []
    private var ttyBySessionID: [String: String] = [:]
    private var lastTopologyCaptureAt: [String: Date] = [:]
    private let topologyRefreshInterval: TimeInterval = 300

    private init() {
        currentBootID = Self.bootID()
        let fileURL = AppPaths.appSupportDirectory()
            .appendingPathComponent(Self.snapshotFileName)
        snapshotStore = PiRestorationSnapshotStore(fileURL: fileURL)
        if let persisted = try? snapshotStore.load() {
            coordinator = PiRebootRestorationCoordinator(snapshot: persisted)
        } else {
            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
        }
    }

    func start(liveSessionIDs: Set<String> = []) async {
        guard !started else { return }
        started = true

        let plan = coordinator.claimRestorePlan(
            currentBootID: currentBootID,
            liveSessionIDs: liveSessionIDs
        ).filter(Self.isValidRestoreCandidate)

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
            persistSnapshot()
        } else if coordinator.snapshot.bootID != currentBootID
                    || coordinator.snapshot.state != .active {
            coordinator = PiRebootRestorationCoordinator(
                bootID: currentBootID,
                generationID: UUID().uuidString
            )
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

    func recordAcceptedSession(
        sessionID: String,
        sessionFile: String,
        cwd: String,
        sessionName: String?,
        tty: String,
        allowTopologyRefresh: Bool
    ) {
        guard started,
              !sessionID.isEmpty,
              !sessionFile.isEmpty,
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

    func end(sessionID: String) {
        guard started else { return }
        let existed = coordinator.snapshot.sessionsByID[sessionID] != nil
        coordinator.end(sessionID: sessionID)
        ttyBySessionID.removeValue(forKey: sessionID)
        topologyCaptureInFlight.remove(sessionID)
        lastTopologyCaptureAt.removeValue(forKey: sessionID)
        if existed && coordinator.snapshot.sessionsByID[sessionID] == nil {
            persistSnapshot()
        }
    }

    func freezeForSystemPowerOff() {
        guard started else { return }
        coordinator.freezeForSystemPowerOff(at: Date())
        persistSnapshot()
    }

    func invalidateForCleanAppTermination() {
        guard started else { return }
        coordinator.invalidateForCleanAppTermination()
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
                  let layout else { return }
            self.coordinator.updateLayout(sessionID: sessionID, layout: layout)
            self.persistSnapshot()
        }
    }

    private func persistSnapshot() {
        do {
            try snapshotStore.save(coordinator.snapshot)
        } catch {
            Self.logger.error("Could not persist Pi restoration snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isValidRestoreCandidate(_ session: PiRestorableSession) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.sessionFile),
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

    private nonisolated static func bootID() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 {
            return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
        }
        let approximateBoot = Date().timeIntervalSince1970 - Foundation.ProcessInfo.processInfo.systemUptime
        return String(Int(approximateBoot))
    }
}
