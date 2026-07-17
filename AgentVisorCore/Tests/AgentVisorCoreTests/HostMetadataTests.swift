import XCTest
@testable import AgentVisorCore

final class HostMetadataTests: XCTestCase {
    func testEveryCaseHasNonEmptyDisplayNameAndFallbackSymbol() {
        for host in TerminalHost.allCases {
            let meta = HostMetadata.metadata(for: host)
            XCTAssertFalse(meta.displayName.isEmpty, "\(host) missing displayName")
            XCTAssertFalse(meta.fallbackSFSymbol.isEmpty, "\(host) missing fallback SF symbol")
        }
    }

    func testKnownHostsCarryBundleIDs() {
        let withBundle: [TerminalHost] = [
            .ghostty, .iterm2, .terminalApp, .claudeDesktop, .codexApp, .vscode, .cursor, .zed
        ]
        for host in withBundle {
            XCTAssertNotNil(HostMetadata.metadata(for: host).bundleID, "\(host)")
        }
    }

    func testCodexAppMetadata() {
        let meta = HostMetadata.metadata(for: .codexApp)
        XCTAssertEqual(meta.displayName, "Codex")
        XCTAssertEqual(meta.bundleID, "com.openai.codex")
        XCTAssertFalse(meta.fallbackSFSymbol.isEmpty)
    }

    func testZedMetadata() {
        let meta = HostMetadata.metadata(for: .zed)
        XCTAssertEqual(meta.displayName, "Zed")
        XCTAssertEqual(meta.bundleID, "dev.zed.Zed")
        XCTAssertFalse(meta.fallbackSFSymbol.isEmpty)
    }

    func testUnknownHasNoBundleID() {
        XCTAssertNil(HostMetadata.metadata(for: .unknown).bundleID)
    }
}
