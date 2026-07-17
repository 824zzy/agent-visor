import XCTest
@testable import AgentVisorCore

/// Fake process tree for tests: maps PID → (parent PID, bundle ID).
struct FakeProcessTree: ProcessInfoReader {
    var nodes: [pid_t: (parent: pid_t?, bundleID: String?)]
    func parentPID(of pid: pid_t) -> pid_t? { nodes[pid]?.parent }
    func bundleID(of pid: pid_t) -> String? { nodes[pid]?.bundleID }
}

final class TerminalHostDetectorTests: XCTestCase {
    func testDirectBundleIDIdentifiesITerm2() {
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "com.googlecode.iterm2"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .iterm2)
    }

    func testWalksParentChainToFindHost() {
        // claude-code (no bundle) -> bash (no bundle) -> Ghostty.
        let tree = FakeProcessTree(nodes: [
            100: (parent: 99,  bundleID: nil),                       // claude-code
            99:  (parent: 50,  bundleID: nil),                       // bash
            50:  (parent: nil, bundleID: "com.mitchellh.ghostty"),   // Ghostty
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 100, reader: tree), .ghostty)
    }

    func testReturnsUnknownWhenNoAncestorMatches() {
        // Long chain with no recognized terminal ancestor — e.g. session
        // started from a launchd-launched script with no terminal at all.
        let tree = FakeProcessTree(nodes: [
            100: (parent: 99,  bundleID: nil),
            99:  (parent: 1,   bundleID: nil),
            1:   (parent: nil, bundleID: "com.apple.launchd"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 100, reader: tree), .unknown)
    }

    func testVSCodeStableBundleIDResolvesToVSCode() {
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "com.microsoft.VSCode"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .vscode)
    }

    func testVSCodeInsidersBundleIDResolvesToVSCode() {
        // Insiders is the same host class as stable. The EditorAdapter
        // is bundle-ID-parameterized, so the host enum doesn't need to
        // distinguish them.
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "com.microsoft.VSCodeInsiders"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .vscode)
    }

    func testCursorBundleIDResolvesToCursor() {
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "com.todesktop.230313mzl4w4u92"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .cursor)
    }

    func testCodexBundleIDResolvesToCodexApp() {
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "com.openai.codex"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .codexApp)
    }

    func testZedBundleIDResolvesToZed() {
        // Direct: a process whose own bundle ID is Zed. (Rare in practice
        // — Zed launches its agent adapters as children — but the rule
        // is the same: if you walk into Zed, you're hosted by Zed.)
        let tree = FakeProcessTree(nodes: [
            42: (parent: nil, bundleID: "dev.zed.Zed"),
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 42, reader: tree), .zed)
    }

    func testZedAcpAgentChainResolvesToZed() {
        // Real Zed claude-acp shape, observed live:
        //   claude (the agent CLI) → node (claude-agent-acp) →
        //   npm exec ... → /Applications/Zed.app
        let tree = FakeProcessTree(nodes: [
            14669: (parent: 14668, bundleID: nil),              // claude
            14668: (parent: 14336, bundleID: nil),              // node (claude-agent-acp)
            14336: (parent: 99918, bundleID: nil),              // npm exec
            99918: (parent: nil,   bundleID: "dev.zed.Zed"),    // Zed.app
        ])
        XCTAssertEqual(TerminalHostDetector.detect(pid: 14669, reader: tree), .zed)
    }
}
