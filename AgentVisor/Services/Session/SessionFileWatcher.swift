//
//  SessionFileWatcher.swift
//  AgentVisor
//
//  Watches the main session JSONL for any append and signals
//  SessionStore to schedule a file sync. Decouples file-driven sync
//  from hook-driven sync so cases without a follow-up hook (e.g.
//  /compact, which writes the boundary line tens of seconds after
//  PreCompact) still surface in the chat view.
//

import AgentVisorCore
import Foundation
import os.log

private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SessionFileWatcher")

protocol SessionFileWatcherDelegate: AnyObject {
    func didExtendSessionFile(sessionId: String, cwd: String)
}

/// Watches a single session JSONL for file extension events.
/// Does NOT read or consume content — only signals "file changed".
/// The actual incremental parse runs in SessionStore via scheduleFileSync.
class SessionFileWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var retryWorkItem: DispatchWorkItem?
    private let sessionId: String
    private let cwd: String
    private let filePath: String
    private let queue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".sessionfilewatcher",
        qos: .userInitiated
    )

    weak var delegate: SessionFileWatcherDelegate?

    init(sessionId: String, cwd: String, agentID: AgentID = .claudeCode) {
        self.sessionId = sessionId
        self.cwd = cwd
        if agentID == .codex, let path = CodexThreadStore.thread(id: sessionId)?.rolloutPath {
            self.filePath = path
        } else if agentID == .cursor {
            self.filePath = CursorAgentProvider().transcriptURL(sessionId: sessionId, cwd: cwd).path
        } else {
            let projectDir = ConversationParser.projectDirName(from: cwd)
            self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            // File may not exist yet for brand-new sessions; retry once.
            logger.debug("File not yet present, retrying in 1s: \(self.sessionId.prefix(8), privacy: .public)")
            let work = DispatchWorkItem { [weak self] in
                self?.startWatching()
            }
            retryWorkItem = work
            queue.asyncAfter(deadline: .now() + 1.0, execute: work)
            return
        }

        fileHandle = handle
        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            let sid = self.sessionId
            let c = self.cwd
            logger.debug("file extended sid=\(sid.prefix(8), privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didExtendSessionFile(sessionId: sid, cwd: c)
            }
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching session file: \(self.sessionId.prefix(8), privacy: .public)")
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if source != nil {
            logger.debug("Stopped watching: \(self.sessionId.prefix(8), privacy: .public)")
        }
        source?.cancel()
        source = nil
    }

    deinit {
        retryWorkItem?.cancel()
        source?.cancel()
    }
}

// MARK: - Manager

/// Owns SessionFileWatcher instances per sessionId.
@MainActor
class SessionFileWatcherManager {
    static let shared = SessionFileWatcherManager()

    private var watchers: [String: SessionFileWatcher] = [:]
    weak var delegate: SessionFileWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, cwd: String, agentID: AgentID = .claudeCode) {
        guard watchers[sessionId] == nil else { return }
        let watcher = SessionFileWatcher(sessionId: sessionId, cwd: cwd, agentID: agentID)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionId] = watcher
    }

    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for (_, w) in watchers { w.stop() }
        watchers.removeAll()
    }

    func isWatching(sessionId: String) -> Bool {
        watchers[sessionId] != nil
    }
}
