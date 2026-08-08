//
//  ZedDatabaseLocator.swift
//  AgentVisorCore
//
//  Resolves which Zed sqlite database to read.
//
//  Zed keeps one data directory for every release channel and separates
//  channels by sqlite scope directory:
//
//      ~/Library/Application Support/Zed/db/0-stable/db.sqlite
//      ~/Library/Application Support/Zed/db/0-preview/db.sqlite
//      ~/Library/Application Support/Zed/db/0-nightly/db.sqlite
//      ~/Library/Application Support/Zed/db/0-dev/db.sqlite
//
//  A machine can have several of these (running stable while a dev build
//  was tried once leaves a stale `0-dev` behind), so picking by layout
//  order alone would read a frozen database — the same failure mode that
//  hid Codex's relocated `state_5.sqlite`. Resolution therefore prefers a
//  channel whose app is actually RUNNING, then falls back to whichever
//  database was most recently written (counting the `-wal` sibling, since
//  Zed runs WAL mode and the main file's mtime lags between checkpoints).
//
//  Pure / value-in-value-out: existence, freshness, and the running-app
//  set are injected so this is unit-testable without touching disk.
//

import Foundation

public enum ZedDatabaseLocator {
    public static let databaseFileName = "db.sqlite"

    /// Zed's macOS data directory. Channel-independent by design.
    public static func dataDirectory(home: String) -> String {
        home + "/Library/Application Support/Zed"
    }

    public static func databasePath(home: String, channel: ZedChannel) -> String {
        dataDirectory(home: home)
            + "/db/"
            + channel.databaseScopeDirectoryName
            + "/"
            + databaseFileName
    }

    /// Candidate databases, stable first. Order is only a tiebreaker.
    public static func candidates(home: String) -> [(channel: ZedChannel, path: String)] {
        ZedChannel.allCases.map { ($0, databasePath(home: home, channel: $0)) }
    }

    /// The database Agent Visor should read, or nil when Zed has never
    /// run on this machine (caller no-ops instead of forking sqlite3).
    ///
    /// - `runningChannels`: channels whose app is currently running. A
    ///   running channel always wins over a fresher-but-quit one, because
    ///   the user's visible Zed threads live in the running app.
    /// - `modifiedAt`: freshness probe; `nil` for every path preserves
    ///   pure layout-order behavior.
    public static func resolve(
        home: String,
        exists: (String) -> Bool,
        modifiedAt: (String) -> Date? = { _ in nil },
        runningChannels: Set<ZedChannel> = []
    ) -> (channel: ZedChannel, path: String)? {
        let present = candidates(home: home).filter { exists($0.path) }
        guard !present.isEmpty else { return nil }

        let running = present.filter { runningChannels.contains($0.channel) }
        let pool = running.isEmpty ? present : running
        guard var best = pool.first else { return nil }

        func freshness(_ path: String) -> Date {
            max(modifiedAt(path) ?? .distantPast,
                modifiedAt(path + "-wal") ?? .distantPast)
        }
        var bestFreshness = freshness(best.path)
        for candidate in pool.dropFirst() where freshness(candidate.path) > bestFreshness {
            best = candidate
            bestFreshness = freshness(candidate.path)
        }
        return best
    }

    /// Files whose mtime/size changes mean "re-read the thread list".
    /// Zed commits into the `-wal` file, so watching only the main
    /// database would miss every rename until the next checkpoint.
    public static func watchPaths(databasePath: String) -> [String] {
        [databasePath, databasePath + "-wal"]
    }
}
