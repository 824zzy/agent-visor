import XCTest
@testable import AgentVisorCore

final class ZedChannelTests: XCTestCase {
    func testBundleIDsMatchZedReleaseChannels() {
        XCTAssertEqual(ZedChannel.stable.bundleID, "dev.zed.Zed")
        XCTAssertEqual(ZedChannel.preview.bundleID, "dev.zed.Zed-Preview")
        XCTAssertEqual(ZedChannel.nightly.bundleID, "dev.zed.Zed-Nightly")
        XCTAssertEqual(ZedChannel.dev.bundleID, "dev.zed.Zed-Dev")
    }

    func testChannelLookupFromBundleID() {
        XCTAssertEqual(ZedChannel.channel(forBundleID: "dev.zed.Zed"), .stable)
        XCTAssertEqual(ZedChannel.channel(forBundleID: "dev.zed.Zed-Nightly"), .nightly)
        XCTAssertNil(ZedChannel.channel(forBundleID: "com.microsoft.VSCode"))
    }

    func testDatabaseScopeDirectoryMatchesZedNaming() {
        XCTAssertEqual(ZedChannel.stable.databaseScopeDirectoryName, "0-stable")
        XCTAssertEqual(ZedChannel.dev.databaseScopeDirectoryName, "0-dev")
    }

    func testDisplayNamesAreUserFacingAppNames() {
        XCTAssertEqual(ZedChannel.stable.displayName, "Zed")
        XCTAssertEqual(ZedChannel.preview.displayName, "Zed Preview")
    }

    func testAllBundleIDsStartsWithStable() {
        XCTAssertEqual(ZedChannel.allBundleIDs.first, "dev.zed.Zed")
        XCTAssertEqual(ZedChannel.allBundleIDs.count, 4)
    }
}

final class ZedDatabaseLocatorTests: XCTestCase {
    private let home = "/Users/dev"

    private func path(_ channel: ZedChannel) -> String {
        "/Users/dev/Library/Application Support/Zed/db/\(channel.databaseScopeDirectoryName)/db.sqlite"
    }

    func testAllChannelsShareOneDataDirectory() {
        XCTAssertEqual(
            ZedDatabaseLocator.dataDirectory(home: home),
            "/Users/dev/Library/Application Support/Zed"
        )
        XCTAssertEqual(ZedDatabaseLocator.databasePath(home: home, channel: .stable), path(.stable))
        XCTAssertEqual(ZedDatabaseLocator.databasePath(home: home, channel: .dev), path(.dev))
    }

    func testReturnsNilWhenZedNeverRan() {
        XCTAssertNil(ZedDatabaseLocator.resolve(home: home, exists: { _ in false }))
    }

    func testSingleChannelResolves() {
        let resolved = ZedDatabaseLocator.resolve(
            home: home,
            exists: { $0 == self.path(.preview) }
        )
        XCTAssertEqual(resolved?.channel, .preview)
        XCTAssertEqual(resolved?.path, path(.preview))
    }

    func testRunningChannelBeatsFresherQuitChannel() {
        // A stale `0-dev` left behind by one dev-build experiment must not
        // win over the stable database the user is actually running.
        let resolved = ZedDatabaseLocator.resolve(
            home: home,
            exists: { $0 == self.path(.stable) || $0 == self.path(.dev) },
            modifiedAt: { candidate in
                candidate == self.path(.dev) ? Date(timeIntervalSince1970: 5_000) : Date(timeIntervalSince1970: 1_000)
            },
            runningChannels: [.stable]
        )
        XCTAssertEqual(resolved?.channel, .stable)
    }

    func testFreshestWinsWhenNoChannelIsRunning() {
        let resolved = ZedDatabaseLocator.resolve(
            home: home,
            exists: { $0 == self.path(.stable) || $0 == self.path(.dev) },
            modifiedAt: { candidate in
                candidate == self.path(.dev) ? Date(timeIntervalSince1970: 5_000) : Date(timeIntervalSince1970: 1_000)
            }
        )
        XCTAssertEqual(resolved?.channel, .dev)
    }

    func testWalFreshnessCountsBecauseZedRunsWalMode() {
        let resolved = ZedDatabaseLocator.resolve(
            home: home,
            exists: { $0 == self.path(.stable) || $0 == self.path(.nightly) },
            modifiedAt: { candidate in
                switch candidate {
                case self.path(.stable): return Date(timeIntervalSince1970: 1_000)
                case self.path(.stable) + "-wal": return Date(timeIntervalSince1970: 9_000)
                case self.path(.nightly): return Date(timeIntervalSince1970: 4_000)
                default: return nil
                }
            }
        )
        XCTAssertEqual(resolved?.channel, .stable)
    }

    func testStableWinsTiesSoResolutionIsDeterministic() {
        let resolved = ZedDatabaseLocator.resolve(
            home: home,
            exists: { _ in true }
        )
        XCTAssertEqual(resolved?.channel, .stable)
    }

    func testWatchPathsIncludeWalSibling() {
        XCTAssertEqual(
            ZedDatabaseLocator.watchPaths(databasePath: "/db.sqlite"),
            ["/db.sqlite", "/db.sqlite-wal"]
        )
    }
}
