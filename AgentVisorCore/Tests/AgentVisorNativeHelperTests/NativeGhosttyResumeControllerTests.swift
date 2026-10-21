import AgentVisorCore
import AgentVisorNativeHelper
import Foundation
import XCTest

final class NativeGhosttyResumeControllerTests: XCTestCase {
    func testLaunchesInstalledQuitGhosttyThroughInjectedNormalAppLaunchAndReadsBackSurface() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-visor-ghostty-resume-\(UUID().uuidString)")
        let cwd = root.appendingPathComponent("project")
        let executable = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        var application: NativeGhosttyTerminalController.ApplicationIdentity?
        var launchCalls = 0
        var script = ""
        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 77, token: "ghostty-launch")
        let controller = NativeGhosttyResumeController(
            resolveApplication: { application },
            execute: { source in
                script = source
                return #"{"status":"created","windowId":"window","tabId":"tab","terminalId":"terminal"}"#
            },
            permission: { true },
            launchApplication: {
                launchCalls += 1
                application = identity
                return true
            },
            readSurface: { pid, terminalID in
                guard pid == identity.pid, terminalID == "terminal" else { return nil }
                return NativeGhosttyAppleEvents.Surface(id: terminalID, title: "Claude", cwd: cwd.path)
            },
            homeDirectory: root.path
        )
        let target = NativeHelperGhosttyResumeTarget(
            attemptId: "attempt",
            sessionId: "123e4567-e89b-12d3-a456-426614174000",
            cwd: cwd.path,
            executable: executable.path,
            profileState: "verified_absent",
            nonce: "0123456789abcdef0123456789abcdef"
        )

        let dispatch = try controller.open(target)

        XCTAssertEqual(launchCalls, 1)
        XCTAssertEqual(dispatch.applicationPID, identity.pid)
        XCTAssertEqual(dispatch.processStartToken, identity.token)
        XCTAssertTrue(script.contains("--resume"))
        XCTAssertTrue(script.contains(target.sessionId))
        XCTAssertFalse(script.contains("CLAUDE_CODE_DISABLE_TERMINAL_TITLE"))
    }

    func testTreatsUncertainScriptOutputAsNonRetryable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-visor-ghostty-resume-\(UUID().uuidString)")
        let cwd = root.appendingPathComponent("project")
        let executable = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = NativeGhosttyTerminalController.ApplicationIdentity(pid: 78, token: "ghostty-uncertain")
        var executeCalls = 0
        let controller = NativeGhosttyResumeController(
            resolveApplication: { identity },
            execute: { _ in executeCalls += 1; return nil },
            permission: { true },
            launchApplication: { XCTFail("running Ghostty should not be relaunched"); return false },
            readSurface: { _, _ in nil },
            homeDirectory: root.path
        )
        let target = NativeHelperGhosttyResumeTarget(
            attemptId: "attempt",
            sessionId: "123e4567-e89b-12d3-a456-426614174000",
            cwd: cwd.path,
            executable: executable.path,
            profileState: "verified_absent",
            nonce: "0123456789abcdef0123456789abcdef"
        )

        XCTAssertThrowsError(try controller.open(target)) { error in
            XCTAssertEqual(error as? NativeGhosttyResumeError, .creationUncertain)
        }
        XCTAssertEqual(executeCalls, 1)
    }
}
