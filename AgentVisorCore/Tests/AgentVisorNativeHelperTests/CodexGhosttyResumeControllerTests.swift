import AgentVisorCore
import AgentVisorNativeHelper
import Foundation
import XCTest

final class CodexGhosttyResumeControllerTests: XCTestCase {
    func testLaunchesCodexV7WithPinnedHomeAndReadsBackSurface() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-visor-codex-resume-\(UUID().uuidString)")
        let home = root.appendingPathComponent(".codex")
        let cwd = root.appendingPathComponent("project")
        let executable = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        var script = ""
        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 77, token: "ghostty-codex")
        let controller = NativeGhosttyResumeController(
            resolveApplication: { identity },
            execute: { source in
                script = source
                return #"{"status":"created","windowId":"window","tabId":"tab","terminalId":"terminal"}"#
            },
            permission: { true },
            launchApplication: { XCTFail("running Ghostty should not be relaunched"); return false },
            readSurface: { pid, terminalID in
                guard pid == identity.pid, terminalID == "terminal" else { return nil }
                return NativeGhosttyAppleEvents.Surface(id: terminalID, title: "Codex", cwd: cwd.path)
            },
            homeDirectory: root.path
        )
        let target = NativeHelperGhosttyResumeTarget(
            attemptId: "attempt",
            provider: "codex_cli",
            sessionId: "019f3931-ec11-7f31-8400-1c8624aa9e4d",
            cwd: cwd.path,
            executable: executable.path,
            configRoot: home.path,
            profileState: "verified_absent",
            nonce: "0123456789abcdef0123456789abcdef"
        )

        let dispatch = try controller.open(target)

        XCTAssertEqual(dispatch.provider, "codex_cli")
        XCTAssertEqual(dispatch.sessionId, target.sessionId)
        XCTAssertTrue(script.contains("CODEX_HOME"))
        XCTAssertTrue(script.contains(target.sessionId))
        XCTAssertTrue(script.contains("--cd"))
    }
}
