import Foundation
import AgentVisorCore

/// Pi integration with two independent evidence paths:
/// - persisted versioned JSONL under ~/.pi/agent/sessions;
/// - a bundled global Pi extension for exact lifecycle hooks.
///
/// The extension is never a discovery prerequisite. Existing sessions remain
/// browsable and terminal-owned sessions remain navigable if it is absent.
struct PiAgentProvider: AgentProvider {
    /// Discovery already reads every Pi transcript header. Keep the paths it
    /// proves, so the synchronous store merge does not repeat that whole tree
    /// walk once per Pi row.
    nonisolated(unsafe) private static var transcriptURLBySessionID: [String: URL] = [:]

    nonisolated private struct TranscriptNameSignature: Equatable {
        let path: String
        let byteCount: UInt64
        let modifiedAt: Date
    }

    nonisolated private struct CachedTranscriptName {
        let signature: TranscriptNameSignature
        let name: String?
    }

    nonisolated(unsafe) private static var transcriptNameBySessionID: [String: CachedTranscriptName] = [:]
    nonisolated private static let transcriptURLCacheLock = NSLock()
    nonisolated let id: AgentID = .pi
    nonisolated let displayName: String = "Pi"
    nonisolated let processNameFilter: String = "pi"
    nonisolated let canRenderChat = true
    nonisolated let transcriptTitleAuthority: SessionTranscriptTitlePolicy.Authority = .authoritative

    nonisolated init() {}

    nonisolated var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi")
            .appendingPathComponent("agent")
    }

    nonisolated var settingsURL: URL {
        configDirectory.appendingPathComponent("settings.json")
    }

    nonisolated var hooksDirectory: URL {
        configDirectory.appendingPathComponent("extensions")
    }

    nonisolated var sessionMetadataDirectory: URL {
        configDirectory.appendingPathComponent("sessions")
    }

    nonisolated var projectsDirectory: URL { sessionMetadataDirectory }

    nonisolated func projectDirName(forCwd cwd: String) -> String {
        "--" + cwd.split(separator: "/").joined(separator: "-") + "--"
    }

    nonisolated func transcriptURLForReading(sessionId: String, cwd: String) async -> URL {
        await BlockingWork.run("piTranscriptURL") {
            transcriptURL(sessionId: sessionId, cwd: cwd)
        }
    }

    nonisolated func transcriptURL(sessionId: String, cwd: String) -> URL {
        if let cached = Self.cachedTranscriptURL(sessionId: sessionId) {
            return cached
        }
        // A hook can introduce a session before the next discovery. Keep the old
        // fallback for that case: one scan finds the path and also refreshes the
        // cache for every other Pi session.
        return Self.sessionFiles().first { $0.metadata.sessionId == sessionId }?.url
            ?? sessionMetadataDirectory
                .appendingPathComponent(projectDirName(forCwd: cwd))
                .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Discovery already has one exact path per visible Pi session. Scan only
    /// record links and session names, then cache by file signature. The next
    /// 30-second discovery skips unchanged files.
    nonisolated func prewarmMetadata(sessionIds: [String]) {
        Self.transcriptURLCacheLock.lock()
        let paths = sessionIds.compactMap { id in
            Self.transcriptURLBySessionID[id].map { (id, $0) }
        }
        Self.transcriptURLCacheLock.unlock()

        for (sessionId, url) in paths {
            Self.refreshTranscriptName(sessionId: sessionId, url: url)
        }
    }

    nonisolated func resolveSessionName(sessionId: String, pid: Int?) -> String? {
        Self.cachedTranscriptName(sessionId: sessionId)
    }

    nonisolated private static func refreshTranscriptName(sessionId: String, url: URL) {
        guard let signature = transcriptNameSignature(url: url) else { return }
        transcriptURLCacheLock.lock()
        transcriptURLBySessionID[sessionId] = url
        let isCurrent = transcriptNameBySessionID[sessionId]?.signature == signature
        transcriptURLCacheLock.unlock()
        guard !isCurrent else { return }

        let name = PiTranscriptActiveNameReader.read(path: url.path)
        // Do not bind an answer to a newer file version than the one it read.
        // A hook during the scan changes the signature and the next event retries.
        guard transcriptNameSignature(url: url) == signature else { return }
        cacheTranscriptName(
            sessionId: sessionId,
            url: url,
            signature: signature,
            name: name
        )
    }

    nonisolated private static func cacheTranscriptName(
        sessionId: String,
        url: URL,
        signature: TranscriptNameSignature,
        name: String?
    ) {
        transcriptURLCacheLock.lock()
        transcriptURLBySessionID[sessionId] = url
        transcriptNameBySessionID[sessionId] = CachedTranscriptName(
            signature: signature,
            name: name
        )
        transcriptURLCacheLock.unlock()
    }

    nonisolated private static func transcriptNameSignature(url: URL) -> TranscriptNameSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        return TranscriptNameSignature(
            path: url.path,
            byteCount: size.uint64Value,
            modifiedAt: modifiedAt
        )
    }

    nonisolated private static func cachedTranscriptName(sessionId: String) -> String? {
        transcriptURLCacheLock.lock()
        let name = transcriptNameBySessionID[sessionId]?.name
        transcriptURLCacheLock.unlock()
        return name
    }

    nonisolated private static func cachedTranscriptURL(sessionId: String) -> URL? {
        transcriptURLCacheLock.lock()
        let cached = transcriptURLBySessionID[sessionId]
        transcriptURLCacheLock.unlock()
        guard let cached else { return nil }
        guard FileManager.default.fileExists(atPath: cached.path) else {
            transcriptURLCacheLock.lock()
            if transcriptURLBySessionID[sessionId] == cached {
                transcriptURLBySessionID.removeValue(forKey: sessionId)
            }
            transcriptURLCacheLock.unlock()
            return nil
        }
        return cached
    }

    // MARK: - Availability and installation

    nonisolated func isAvailable() -> Bool { Self.isPiAvailable() }

    nonisolated func installHooks() throws {
        guard Self.isPiAvailable() else { return }
        guard let bundled = Bundle.main.url(
            forResource: Self.extensionResourceName,
            withExtension: "txt"
        ) else { return }

        try FileManager.default.createDirectory(
            at: hooksDirectory,
            withIntermediateDirectories: true
        )
        let target = hooksDirectory.appendingPathComponent(Self.extensionFileName)
        if FileManager.default.fileExists(atPath: target.path),
           FileManager.default.contentsEqual(atPath: bundled.path, andPath: target.path) {
            return
        }

        let temporary = hooksDirectory.appendingPathComponent(".\(Self.extensionFileName).tmp")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: bundled, to: temporary)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    nonisolated func uninstallHooks() {
        try? FileManager.default.removeItem(
            at: hooksDirectory.appendingPathComponent(Self.extensionFileName)
        )
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(
            atPath: hooksDirectory.appendingPathComponent(Self.extensionFileName).path
        )
    }

    nonisolated private static let extensionFileName = "agent-visor.ts"
    nonisolated private static let extensionResourceName = "agent-visor-pi.ts"

    nonisolated static func isPiAvailable() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let configRoot = home + "/.pi/agent"
        if fm.fileExists(atPath: configRoot) { return true }

        let live = AgentDiscoveryUtilities.runProcess(
            "/usr/bin/pgrep",
            arguments: ["-x", "pi"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return true }

        let candidates = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            home + "/.local/bin/pi",
        ]
        if candidates.contains(where: fm.isExecutableFile(atPath:)) { return true }

        let nvmRoot = home + "/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) else { return false }
        return versions.contains { version in
            fm.isExecutableFile(atPath: nvmRoot + "/" + version + "/bin/pi")
        }
    }

    // MARK: - Discovery

    nonisolated func discoverLiveSessions() -> [DiscoveredSession] {
        guard Self.isPiAvailable() else { return [] }
        // Pi can be installed after Agent Visor launches. Discovery doubles
        // as the periodic, idempotent installation opportunity so users do
        // not need to restart either application or configure Pi manually.
        try? installHooks()

        let files = Self.sessionFiles()
        let processes = Self.liveProcesses()
        let matches = PiProcessSessionMatcher.match(
            processes: processes,
            sessions: files.map {
                PiSessionCandidate(
                    id: $0.metadata.sessionId,
                    cwd: $0.metadata.cwd,
                    createdAt: $0.metadata.createdAt
                )
            },
            tolerance: 5
        )

        let fileByID = Dictionary(uniqueKeysWithValues: files.map { ($0.metadata.sessionId, $0) })
        var discovered = matches.compactMap { match -> DiscoveredSession? in
            guard fileByID[match.session.id] != nil,
                  let pid = Int(match.process.id) else { return nil }
            AgentDiscoveryUtilities.writeLog(
                "[Discovery] Found Pi: \(match.session.id.prefix(8)) PID=\(pid) tty=\(match.process.tty ?? "none") cwd=\(match.session.cwd)"
            )
            return DiscoveredSession(
                sessionId: match.session.id,
                cwd: match.session.cwd,
                pid: pid,
                tty: match.process.tty,
                agentID: id
            )
        }
        let alreadyFound = Set(discovered.map(\.sessionId))
        discovered.append(contentsOf: Self.zedHostedSessions(
            files: fileByID,
            excluding: alreadyFound
        ))
        return discovered
    }

    /// Pi threads Zed is hosting over ACP.
    ///
    /// The `ps` path above cannot see these: Zed spawns `node …/pi-acp`,
    /// so `pgrep -x pi` never matches, and the child has no tty (which the
    /// process scan also requires). They were therefore invisible as live
    /// sessions — they surfaced only as historical rows with no pid and no
    /// host, which made a pill click fall through to the Claude Desktop
    /// fallback and activate the wrong app entirely.
    ///
    /// Zed's own thread list is the right source here: it knows the pi
    /// session id, the worktree, and that Zed owns the thread. Liveness
    /// then follows the existing Zed rule (Zed running + transcript not
    /// idle) rather than a pid that is shared across threads.
    nonisolated private static func zedHostedSessions(
        files: [String: SessionFile],
        excluding excluded: Set<String>
    ) -> [DiscoveredSession] {
        guard ZedThreadStore.isZedRunning else { return [] }
        return ZedThreadStore.liveThreads(agentID: .pi).compactMap { thread in
            guard let sessionID = thread.sessionID,
                  !excluded.contains(sessionID),
                  let file = files[sessionID] else { return nil }
            AgentDiscoveryUtilities.writeLog(
                "[Discovery] Found Pi in Zed: \(sessionID.prefix(8)) cwd=\(file.metadata.cwd)"
            )
            return DiscoveredSession(
                sessionId: sessionID,
                // The transcript header is authoritative for cwd; Zed's
                // worktree can be a parent of the session's directory.
                cwd: file.metadata.cwd,
                pid: 0,
                tty: nil,
                agentID: .pi,
                terminalHost: .zed
            )
        }
    }

    nonisolated func discoverHistoricalSessions(
        excluding liveIds: Set<String>,
        limit: Int
    ) -> [DiscoveredSession] {
        let results = Self.sessionFiles()
            .filter { !liveIds.contains($0.metadata.sessionId) && $0.byteCount > $0.headerByteCount }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map {
                DiscoveredSession(
                    sessionId: $0.metadata.sessionId,
                    cwd: $0.metadata.cwd,
                    pid: 0,
                    tty: nil,
                    agentID: id
                )
            }
        if !results.isEmpty {
            AgentDiscoveryUtilities.writeLog("[Discovery] Found \(results.count) historical Pi sessions")
        }
        return Array(results)
    }

    private struct SessionFile {
        let metadata: PiTranscriptMetadata
        let url: URL
        let modifiedAt: Date
        let byteCount: Int
        let headerByteCount: Int
    }

    nonisolated private static func sessionFiles() -> [SessionFile] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi")
            .appendingPathComponent("agent")
            .appendingPathComponent("sessions")
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let byteCount = values.fileSize,
                  let header = readHeader(url: url) else { continue }
            result.append(SessionFile(
                metadata: header.metadata,
                url: url,
                modifiedAt: modifiedAt,
                byteCount: byteCount,
                headerByteCount: header.byteCount
            ))
        }
        // Preserve the enumerator's first match for duplicate ids, which is the
        // same answer `transcriptURL` gave before the cache existed.
        let urls = result.reduce(into: [String: URL]()) { paths, file in
            if paths[file.metadata.sessionId] == nil {
                paths[file.metadata.sessionId] = file.url
            }
        }
        transcriptURLCacheLock.lock()
        transcriptURLBySessionID = urls
        transcriptURLCacheLock.unlock()
        return result
    }

    nonisolated private static func readHeader(url: URL) -> (metadata: PiTranscriptMetadata, byteCount: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 64 * 1024),
              let newline = prefix.firstIndex(of: 0x0A) else { return nil }
        let line = prefix[..<newline]
        guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              json["type"] as? String == "session",
              let id = json["id"] as? String,
              let cwd = json["cwd"] as? String,
              let timestamp = json["timestamp"] as? String,
              let createdAt = parseISO8601(timestamp) else { return nil }
        return (
            PiTranscriptMetadata(sessionId: id, cwd: cwd, createdAt: createdAt),
            line.count + 1
        )
    }

    nonisolated private static func liveProcesses() -> [PiProcessCandidate] {
        let pidOutput = AgentDiscoveryUtilities.runProcess(
            "/usr/bin/pgrep",
            arguments: ["-x", "pi"]
        )
        return pidOutput.split(separator: "\n").compactMap { rawPID in
            guard let pid = Int(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let cwd = AgentDiscoveryUtilities.cwdForProcess(pid: pid) else { return nil }
            let tty = TTYNormalizer.normalize(AgentDiscoveryUtilities.runProcess(
                "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "tty="]
            ))
            guard tty != nil else { return nil }
            let rawStart = AgentDiscoveryUtilities.runProcess(
                "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "lstart="]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let startedAt = parseProcessDate(rawStart) else { return nil }
            return PiProcessCandidate(
                id: String(pid),
                cwd: cwd,
                startedAt: startedAt,
                tty: tty
            )
        }
    }

    nonisolated private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    nonisolated private static func parseProcessDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: value)
    }

    // MARK: - Transcript and lifecycle

    nonisolated func loadFullHistory(sessionId: String, cwd: String) async -> ParsedHistory {
        let path = transcriptURL(sessionId: sessionId, cwd: cwd).path
        return await PiConversationParser.shared.loadHistory(
            sessionId: sessionId,
            transcriptPath: path
        ).history
    }

    nonisolated func loadConversationInfo(sessionId: String, cwd: String) async -> ConversationInfo {
        let path = (await transcriptURLForReading(sessionId: sessionId, cwd: cwd)).path
        // Bounded: a scan asks for one of these per row, and this one reads a
        // transcript from disk.
        return await BlockingWork.limited("piSummary") {
            await PiConversationSummary.shared.loadConversationInfo(
                sessionId: sessionId,
                transcriptPath: path
            )
        }
    }

    nonisolated func fileSync(sessionId: String, cwd: String) async -> FileSyncOutcome {
        let url = transcriptURL(sessionId: sessionId, cwd: cwd)
        let result = await PiConversationParser.shared.loadHistory(
            sessionId: sessionId,
            transcriptPath: url.path
        )
        if result.fileChange != nil {
            await BlockingWork.run("piSessionName") {
                Self.refreshTranscriptName(sessionId: sessionId, url: url)
            }
        }
        return result.didChange ? .fullReplay(result.history) : .noChange
    }

    nonisolated func originForSession(sessionId: String, tty: String?) -> SessionOrigin {
        tty == nil ? .observed : .terminal
    }

    nonisolated func overwritesModelName() -> Bool { true }

    // MARK: - Pi's own notes

    /// Pi ships a bundled extension that reports over a unix socket. One event
    /// of any kind proves the extension is loaded and reporting, which the
    /// integration health check reads. A dropped event still proves it, so the
    /// store calls this before any rule can drop one.
    nonisolated func noteRuntimeReportedIn() async {
        await MainActor.run {
            PiIntegrationMonitor.shared.recordHeartbeat()
        }
    }

    /// Keep the record used to restore Pi sessions after a reboot.
    ///
    /// A terminal status ends the record. A live event marks the session live,
    /// and a session running in Ghostty with its own process and tty becomes a
    /// restoration candidate, because those three facts are what a restore
    /// needs to reopen it. Anything else drops the candidate: a session with no
    /// tty or no process cannot be reopened, and keeping it would restore a row
    /// that cannot run.
    ///
    /// A heartbeat must not refresh the terminal topology. It arrives every ten
    /// seconds and would keep re-reading window layout for no new information.
    nonisolated func noteHookEvent(_ event: HookEvent, session: SessionState) async {
        let sessionId = session.sessionId
        let eventPath = event.sessionFile
        let cwd = session.cwd
        await BlockingWork.run("piSessionName") {
            let url = eventPath.map(URL.init(fileURLWithPath:))
                ?? transcriptURL(sessionId: sessionId, cwd: cwd)
            Self.refreshTranscriptName(sessionId: sessionId, url: url)
        }
        if event.isTerminalLifecycleStatus {
            await MainActor.run {
                PiRebootRestorationManager.shared.noteExactSessionEnded(sessionID: sessionId)
                PiRebootRestorationManager.shared.end(sessionID: sessionId)
            }
            return
        }
        await MainActor.run {
            PiRebootRestorationManager.shared.noteExactLiveSession(sessionID: sessionId)
        }
        guard session.terminalHost == .ghostty,
              session.origin == .terminal,
              let pid = session.pid, pid > 0,
              let tty = session.tty, !tty.isEmpty
        else {
            await MainActor.run {
                PiRebootRestorationManager.shared.removeRestorationCandidate(sessionID: sessionId)
            }
            return
        }
        let sessionFile = event.sessionFile
            ?? transcriptURL(sessionId: sessionId, cwd: session.cwd).path
        let allowTopologyRefresh = !PiSessionHeartbeatPolicy.isHeartbeat(
            agentID: event.agentID,
            lifecycleEvent: event.event
        )
        let sessionName = Self.cachedTranscriptName(sessionId: sessionId)
            ?? session.sessionName
        await MainActor.run {
            PiRebootRestorationManager.shared.recordAcceptedSession(
                sessionID: sessionId,
                sessionFile: sessionFile,
                cwd: cwd,
                sessionName: sessionName,
                tty: tty,
                allowTopologyRefresh: allowTopologyRefresh
            )
        }
    }

    nonisolated func noteSessionGone(sessionId: String) async {
        await MainActor.run {
            PiRebootRestorationManager.shared.end(sessionID: sessionId)
        }
    }
}
