//
//  CodexDatabaseLocatorTests.swift
//  AgentVisorCoreTests
//
//  Codex relocated state_5.sqlite from ~/.codex/ into ~/.codex/sqlite/.
//  The locator must prefer the live nested path, fall back to the legacy
//  flat path for older installs, and pick a sane default when neither
//  exists yet.
//

import XCTest
@testable import AgentVisorCore

final class CodexDatabaseLocatorTests: XCTestCase {
    private let home = "/Users/test"

    func testPrefersNestedSqliteDirWhenItExists() {
        let nested = "/Users/test/.codex/sqlite/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(home: home) { $0 == nested }
        XCTAssertEqual(path, nested)
    }

    func testFallsBackToLegacyFlatPathForOlderInstalls() {
        let flat = "/Users/test/.codex/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(home: home) { $0 == flat }
        XCTAssertEqual(path, flat)
    }

    func testPrefersNestedWhenBothExistAndNoFreshnessGiven() {
        // Without mtimes to compare, fall back to layout order: nested wins.
        let path = CodexDatabaseLocator.resolve(home: home) { _ in true }
        XCTAssertEqual(path, "/Users/test/.codex/sqlite/state_5.sqlite")
    }

    func testPicksFresherFlatWhenNestedIsStale() {
        // The observed bug: live DB is the FLAT path (Codex committing every
        // turn) while a stale copy lingers nested. Freshness must pick flat.
        let nested = "/Users/test/.codex/sqlite/state_5.sqlite"
        let flat = "/Users/test/.codex/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(
            home: home,
            exists: { _ in true },
            modifiedAt: { $0 == flat ? Date(timeIntervalSince1970: 2_000)
                                     : ($0 == nested ? Date(timeIntervalSince1970: 1_000) : nil) }
        )
        XCTAssertEqual(path, flat)
    }

    func testFreshnessCountsWalSibling() {
        // WAL commits bump only `-wal`, not the main file. The flat DB's main
        // mtime is older, but its `-wal` is newest → flat is the live DB.
        let nested = "/Users/test/.codex/sqlite/state_5.sqlite"
        let flat = "/Users/test/.codex/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(
            home: home,
            exists: { _ in true },
            modifiedAt: { p in
                switch p {
                case nested:        return Date(timeIntervalSince1970: 5_000)
                case flat:          return Date(timeIntervalSince1970: 1_000)
                case flat + "-wal": return Date(timeIntervalSince1970: 9_000)
                default:            return nil
                }
            }
        )
        XCTAssertEqual(path, flat)
    }

    func testNestedWinsWhenItIsFresher() {
        let nested = "/Users/test/.codex/sqlite/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(
            home: home,
            exists: { _ in true },
            modifiedAt: { $0 == nested ? Date(timeIntervalSince1970: 9_000)
                                       : Date(timeIntervalSince1970: 1_000) }
        )
        XCTAssertEqual(path, nested)
    }

    func testSinglePresentCandidateUsedRegardlessOfFreshness() {
        // Only the flat file exists → use it even though nested is the
        // preferred layout and no mtime is supplied.
        let flat = "/Users/test/.codex/state_5.sqlite"
        let path = CodexDatabaseLocator.resolve(
            home: home,
            exists: { $0 == flat },
            modifiedAt: { _ in nil }
        )
        XCTAssertEqual(path, flat)
    }

    func testDefaultsToNestedPathWhenNeitherExists() {
        // Fresh machine / Codex never run: return the newest-layout path
        // so the caller's fileExists guard no-ops cleanly.
        let path = CodexDatabaseLocator.resolve(home: home) { _ in false }
        XCTAssertEqual(path, "/Users/test/.codex/sqlite/state_5.sqlite")
    }

    func testCandidateOrderIsNestedThenFlat() {
        XCTAssertEqual(
            CodexDatabaseLocator.candidatePaths(home: home),
            [
                "/Users/test/.codex/sqlite/state_5.sqlite",
                "/Users/test/.codex/state_5.sqlite",
            ]
        )
    }
}
