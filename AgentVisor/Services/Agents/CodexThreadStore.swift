//
//  CodexThreadStore.swift
//  AgentVisor
//
//  Read-only access to Codex Desktop/CLI's local thread index.
//
//  Each query forks `/usr/bin/sqlite3 -readonly`. The `-readonly` flag
//  is load-bearing: codex itself writes `state_5.sqlite` continuously,
//  and a default sqlite3 invocation can race with the writer (and would
//  also try to crash-recover the WAL on our behalf). We never write,
//  so opening read-only avoids the conflict entirely.
//
//  Results are cached in-process keyed by `(sql, metadata signature)`.
//  Codex writes both sqlite/WAL state and `session_index.jsonl`, so the
//  signature includes all of those files. Bootstrap with N codex sessions
//  previously fanned out N+ subprocess invocations; with the cache it does
//  at most one per distinct query per signature.
//

import Foundation
import AgentVisorCore
import os.log

extension Notification.Name {
    static let cvCodexCatalogDidChange = Notification.Name("AgentVisor.codexCatalogDidChange")
}

enum CodexThreadStore {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "CodexThreadStore")
    nonisolated(unsafe) private static var cache: [String: CachedQuery] = [:]
    nonisolated(unsafe) private static var titleCache: (
        signature: CodexMetadataSignature,
        titles: [String: String]
    )?
    nonisolated(unsafe) private static var liveSnapshot: LiveQuerySnapshot?
    nonisolated private static let cacheLock = NSLock()

    nonisolated private static let liveThreadsSQL = """
    select id, rollout_path, cwd, substr(title, 1, 500) as title, updated_at, archived, source
    from threads
    where archived = 0
       OR (archived = 1 AND updated_at >= strftime('%s','now') - 86400)
    order by updated_at desc
    limit 200
    """

    nonisolated private static let browsableThreadsSQL = """
    select id, rollout_path, cwd, substr(title, 1, 500) as title, updated_at, archived, source
    from threads
    where archived = 0 AND source = 'vscode'
    order by updated_at desc
    limit 2000
    """

    /// Live `state_5.sqlite` path. Codex moved the DB from the flat
    /// `~/.codex/state_5.sqlite` into a `sqlite/` subdirectory and left
    /// the old file behind as a stale leftover; reading the dead path
    /// failed with sqlite exit 14 and Codex sessions vanished from the
    /// pills/sidebar. `CodexDatabaseLocator` prefers the live nested path
    /// and falls back to the legacy flat path for older installs.
    nonisolated private static var databasePath: String {
        CodexDatabaseLocator.resolve(
            home: NSHomeDirectory(),
            exists: { FileManager.default.fileExists(atPath: $0) },
            // Pick the candidate Codex is actively writing. When both the
            // nested and flat layouts exist, the stale leftover would
            // otherwise win on layout order alone and freeze the thread
            // list ~38h back (the "why are Codex sessions missing" bug).
            modifiedAt: {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
        )
    }

    nonisolated private static var sessionIndexPath: String {
        NSHomeDirectory() + "/.codex/session_index.jsonl"
    }

    /// Change-detector for the cache key. Codex runs the db in WAL mode, so
    /// commits land in `state_5.sqlite-wal` and the MAIN file's mtime stays
    /// static between checkpoints. Keying the cache on the main mtime alone
    /// (the old behavior) meant the cache never invalidated on a new turn —
    /// and, worse, a once-cached empty result (a truncated read during a
    /// codex write) stayed frozen for a long time, making Codex sessions
    /// vanish from the sidebar until the next checkpoint. Folding the `-wal`
    /// file's mtime + size in makes every commit bump the signature.
    /// `session_index.jsonl` is included because Codex can append rename
    /// records there; `sessionIndexTitles()` prefers those titles over
    /// the sqlite `threads.title` value.
    nonisolated private static func metadataSignature(
        databasePath: String
    ) -> CodexMetadataSignature {
        func stamp(_ path: String) -> CodexMetadataFileStamp {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return .missing
            }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            return CodexMetadataFileStamp(modifiedAt: mtime, size: size)
        }
        return CodexMetadataSignature(
            databasePath: databasePath,
            database: stamp(databasePath),
            wal: stamp(databasePath + "-wal"),
            sessionIndex: stamp(sessionIndexPath)
        )
    }

    nonisolated static func metadataWatchPaths() -> [String] {
        let resolvedDatabasePath = databasePath
        return [
            resolvedDatabasePath,
            resolvedDatabasePath + "-wal",
            sessionIndexPath
        ]
    }

    nonisolated static func thread(id: String) -> CodexThreadCandidate? {
        if let candidate = liveThreadCandidate(id: id) {
            return candidate
        }

        // Codex thread ids are UUIDs in practice; the single-quote
        // doubling here is defense-in-depth, not a real escape barrier.
        let escaped = id.replacingOccurrences(of: "'", with: "''")
        let query = """
        select id, rollout_path, cwd, substr(title, 1, 500) as title, updated_at, archived, source
        from threads
        where id = '\(escaped)'
        limit 1
        """
        return queryThreads(sql: query).first
    }

    nonisolated static func liveThreadCandidates() -> [CodexThreadCandidate] {
        // Non-archived rows, PLUS archived rows touched in the last 24h.
        // Codex flips background-research GUI threads to archived=1 the instant
        // they start yet keeps writing them; the pure selector decides which
        // of those archived rows are actually running (fresh rollout mtime
        // within `runningArchivedWindowSeconds`). The 24h bound (≫ that window)
        // keeps ancient archived history out so the `limit 200` isn't crowded.
        return queryThreads(sql: liveThreadsSQL)
    }

    /// Full navigable Codex Desktop catalog for the Sessions browser.
    /// Unlike live discovery, this deliberately has no observed-window
    /// cutoff. Explicitly archived, automation, observer, and missing-rollout
    /// rows are removed by the pure selector before they reach the UI.
    nonisolated static func browsableThreadCandidates() -> [CodexThreadCandidate] {
        CodexBrowsableThreadSelector.browsableThreads(
            queryThreads(sql: browsableThreadsSQL)
        )
    }

    /// Drop cached results — call after codex installs/removes hooks
    /// or any other moment we know our snapshot is stale and don't want
    /// to wait for codex to bump mtime naturally.
    nonisolated static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        titleCache = nil
        liveSnapshot = nil
        cacheLock.unlock()
    }

    nonisolated private static func liveThreadCandidate(
        id: String
    ) -> CodexThreadCandidate? {
        let resolvedDatabasePath = databasePath
        let signature = metadataSignature(databasePath: resolvedDatabasePath)

        cacheLock.lock()
        if let snapshot = liveSnapshot, snapshot.signature == signature {
            let row = snapshot.rowsById[id]
            let titles = snapshot.titles
            cacheLock.unlock()
            return row.flatMap {
                candidates(from: [$0], sessionIndexTitles: titles).first
            }
        }
        cacheLock.unlock()

        _ = queryThreads(sql: liveThreadsSQL)

        cacheLock.lock()
        let snapshot = liveSnapshot
        let row = snapshot?.signature == signature ? snapshot?.rowsById[id] : nil
        let titles = snapshot?.signature == signature ? snapshot?.titles : nil
        cacheLock.unlock()
        guard let row, let titles else { return nil }
        return candidates(from: [row], sessionIndexTitles: titles).first
    }

    nonisolated private static func queryThreads(sql: String) -> [CodexThreadCandidate] {
        let resolvedDatabasePath = databasePath
        guard FileManager.default.fileExists(atPath: resolvedDatabasePath) else { return [] }

        let signature = metadataSignature(databasePath: resolvedDatabasePath)

        cacheLock.lock()
        if let entry = cache[sql], entry.signature == signature {
            if sql == liveThreadsSQL {
                liveSnapshot = LiveQuerySnapshot(
                    signature: signature,
                    rowsById: rowsById(entry.rows),
                    titles: entry.titles
                )
            }
            cacheLock.unlock()
            logger.debug("cache hit sql.prefix=\(sql.prefix(40), privacy: .public)")
            return candidates(from: entry.rows, sessionIndexTitles: entry.titles)
        }
        cacheLock.unlock()

        let result = ProcessExecutor.shared.runSync(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-json", resolvedDatabasePath, sql]
        )
        guard case .success(let output) = result,
              let data = output.data(using: .utf8) else {
            // Loud on failure: a silent empty here is exactly how the
            // last DB relocation hid for so long (sqlite exit 14 →
            // empty thread list → no Codex pills, no error). If this
            // fires repeatedly, the db path is probably wrong again.
            if case .failure(let error) = result {
                logger.error("sqlite read FAILED db=\(resolvedDatabasePath, privacy: .public) err=\(String(describing: error), privacy: .public)")
            }
            return []
        }
        // Empty result is valid sqlite3 -json output (zero rows → empty
        // string, not `[]`). Treat decode failure on empty as zero rows.
        let rows: [ThreadRow] = (try? JSONDecoder().decode([ThreadRow].self, from: data)) ?? []
        let titles = sessionIndexTitles(for: signature)
        let candidates = candidates(from: rows, sessionIndexTitles: titles)
        // Never cache an empty result. An empty list is almost always a
        // transient read failure (truncated output while codex was writing,
        // a momentary lock), not a real "no threads" state. Caching it would
        // freeze the sidebar empty until the signature next changes; skipping
        // the cache lets the next 3s discovery cycle self-heal.
        if !candidates.isEmpty {
            cacheLock.lock()
            cache[sql] = CachedQuery(signature: signature, rows: rows, titles: titles)
            if sql == liveThreadsSQL {
                liveSnapshot = LiveQuerySnapshot(
                    signature: signature,
                    rowsById: rowsById(rows),
                    titles: titles
                )
            }
            cacheLock.unlock()
        }
        logger.debug("cache miss sql.prefix=\(sql.prefix(40), privacy: .public) rows=\(candidates.count, privacy: .public)")
        return candidates
    }

    nonisolated private static func rowsById(_ rows: [ThreadRow]) -> [String: ThreadRow] {
        rows.reduce(into: [:]) { result, row in
            result[row.id] = row
        }
    }

    nonisolated private static func candidates(
        from rows: [ThreadRow],
        sessionIndexTitles: [String: String]
    ) -> [CodexThreadCandidate] {
        rows.compactMap { row -> CodexThreadCandidate? in
            guard !row.id.isEmpty, !row.rolloutPath.isEmpty, !row.cwd.isEmpty else {
                return nil
            }
            let rolloutModifiedAt = rolloutModifiedAt(path: row.rolloutPath)
            return CodexThreadCandidate(
                id: row.id,
                rolloutPath: row.rolloutPath,
                cwd: row.cwd,
                title: sessionIndexTitles[row.id] ?? row.title,
                updatedAt: CodexThreadActivityPolicy.effectiveUpdatedAt(
                    sqliteUpdatedAt: row.updatedAt,
                    rolloutModifiedAt: rolloutModifiedAt
                ),
                archived: row.archived != 0,
                source: row.source ?? "",
                rolloutModifiedAt: rolloutModifiedAt
            )
        }
    }

    nonisolated private static func rolloutModifiedAt(path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Int(modDate.timeIntervalSince1970)
    }

    nonisolated private struct ThreadRow: Decodable, Sendable {
        let id: String
        let rolloutPath: String
        let cwd: String
        let title: String?
        let updatedAt: Int
        let archived: Int
        let source: String?

        enum CodingKeys: String, CodingKey {
            case id
            case rolloutPath = "rollout_path"
            case cwd
            case title
            case updatedAt = "updated_at"
            case archived
            case source
        }
    }

    nonisolated private struct CachedQuery: Sendable {
        let signature: CodexMetadataSignature
        let rows: [ThreadRow]
        let titles: [String: String]
    }

    nonisolated private struct LiveQuerySnapshot: Sendable {
        let signature: CodexMetadataSignature
        let rowsById: [String: ThreadRow]
        let titles: [String: String]
    }

    nonisolated private static func sessionIndexTitles(
        for signature: CodexMetadataSignature
    ) -> [String: String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let titleCache, titleCache.signature == signature {
            return titleCache.titles
        }
        guard let content = try? String(contentsOfFile: sessionIndexPath, encoding: .utf8) else {
            titleCache = (signature, [:])
            return [:]
        }
        let titles = CodexSessionIndexTitleParser.titlesByThreadId(from: content)
        titleCache = (signature, titles)
        return titles
    }
}

@MainActor
protocol CodexMetadataWatcherDelegate: AnyObject {
    func didChangeCodexMetadata()
}

@MainActor
final class CodexMetadataWatcher {
    static let shared = CodexMetadataWatcher()

    weak var delegate: CodexMetadataWatcherDelegate?

    private var watchers: [String: CodexMetadataFileWatcher] = [:]
    private var debounceTask: Task<Void, Never>?

    func start() {
        let paths = CodexThreadStore.metadataWatchPaths()
        let live = Set(paths)
        let existingPaths = Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
        for path in watchers.keys where !existingPaths.contains(path) {
            watchers[path]?.stop()
            watchers.removeValue(forKey: path)
        }
        for path in existingPaths where watchers[path] == nil {
            let watcher = CodexMetadataFileWatcher(path: path) { [weak self] in
                Task { @MainActor in
                    self?.handleChange()
                }
            }
            watcher.start()
            watchers[path] = watcher
        }
        for path in watchers.keys where !live.contains(path) {
            watchers[path]?.stop()
            watchers.removeValue(forKey: path)
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
    }

    private func handleChange() {
        CodexThreadStore.invalidateCache()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.start()
                self?.delegate?.didChangeCodexMetadata()
                NotificationCenter.default.post(
                    name: .cvCodexCatalogDidChange,
                    object: nil
                )
            }
        }
    }
}

private final class CodexMetadataFileWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".codexmetadata",
        qos: .utility
    )
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func startInternal() {
        stopInternal()
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        fileHandle = handle
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            self?.onChange()
        }
        let handleToClose = handle
        newSource.setCancelHandler {
            try? handleToClose.close()
        }
        source = newSource
        newSource.resume()
    }

    private func stopInternal() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }

    deinit {
        source?.cancel()
    }
}
