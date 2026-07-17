//
//  CodexDatabaseLocator.swift
//  AgentVisorCore
//
//  Resolves the path to Codex's live `state_5.sqlite` thread index.
//
//  History: Codex originally kept the DB flat at `~/.codex/state_5.sqlite`.
//  A later Codex build relocated it into a `sqlite/` subdirectory
//  (`~/.codex/sqlite/state_5.sqlite`) — and left the old flat file behind
//  as a stale, never-updated leftover. CodexThreadStore had the flat path
//  hardcoded, so every read hit the dead file (sqlite exit 14, "unable to
//  open database file"), the thread list came back empty, and Codex GUI
//  sessions vanished from the pills/sidebar. Worse, the metadata file
//  watcher (which derives its watch paths from this same location) was
//  watching the dead file, so it never fired — Codex sessions stopped
//  refreshing in anything close to real time.
//
//  This locator prefers whichever candidate Codex is actually WRITING and
//  falls back to layout order only when freshness can't be told apart.
//  Pure / value-in-value-out (existence + mtime injected) so it's
//  unit-testable without touching disk.
//
//  Why freshness, not a fixed nested-first preference: BOTH layouts can
//  exist at once, and which one is live varies by install. Observed in the
//  wild: a machine whose live DB is the FLAT `~/.codex/state_5.sqlite`
//  (Codex committing every turn) while a STALE copy lingered at the nested
//  `~/.codex/sqlite/state_5.sqlite`, frozen ~38h back. A blind nested-first
//  pick read the dead file, so the sidebar/pills showed a frozen subset of
//  Codex GUI threads and missed every recent one. Picking the most-recently
//  written candidate (counting its `-wal` sibling, since WAL commits don't
//  bump the main file between checkpoints) tracks the live DB either way.
//

import Foundation

public enum CodexDatabaseLocator {
    /// Candidate `state_5.sqlite` locations. Order is the tiebreaker used
    /// only when freshness can't distinguish them (or no mtime is given);
    /// nested first because that's the current default Codex layout.
    public static func candidatePaths(home: String) -> [String] {
        [
            home + "/.codex/sqlite/state_5.sqlite",
            home + "/.codex/state_5.sqlite",
        ]
    }

    /// The live DB path.
    ///
    /// - Several candidates exist → pick the one most recently written (its
    ///   own mtime or its `-wal`'s, whichever is newer) — the DB Codex is
    ///   actively committing to. Ties / missing mtimes fall back to
    ///   candidate order (nested first).
    /// - Exactly one exists → use it.
    /// - None exist (fresh machine, Codex never run) → newest-layout path as
    ///   a stable default so the caller's `fileExists` guard no-ops cleanly.
    ///
    /// `modifiedAt(path)` returns a path's modification date, nil if absent.
    /// Default returns nil for every path, preserving pure layout-order
    /// behavior for callers that don't supply freshness.
    public static func resolve(
        home: String,
        exists: (String) -> Bool,
        modifiedAt: (String) -> Date? = { _ in nil }
    ) -> String {
        let candidates = candidatePaths(home: home)
        let present = candidates.filter(exists)

        guard let firstPresent = present.first else {
            return candidates.first ?? (home + "/.codex/sqlite/state_5.sqlite")
        }
        if present.count == 1 { return firstPresent }

        // Multiple present: choose the freshest by max(file, file-wal) mtime.
        // Iterating present-in-order with a strict `>` makes candidate order
        // the deterministic tiebreaker (nested wins on equal freshness).
        func freshness(_ path: String) -> Date {
            max(modifiedAt(path) ?? .distantPast,
                modifiedAt(path + "-wal") ?? .distantPast)
        }
        var best = firstPresent
        var bestFreshness = freshness(firstPresent)
        for path in present.dropFirst() where freshness(path) > bestFreshness {
            best = path
            bestFreshness = freshness(path)
        }
        return best
    }
}
