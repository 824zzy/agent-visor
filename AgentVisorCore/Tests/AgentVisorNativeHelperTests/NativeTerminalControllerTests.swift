import AgentVisorCore
import AgentVisorNativeHelper
import XCTest
import Foundation

final class NativeTerminalControllerTests: XCTestCase {
    private let target = NativeHelperTerminalTarget(
        application: .terminal,
        pid: 42,
        processStartToken: "start-a",
        tty: "ttys012",
        cwd: "/tmp/project"
    )

    func testInjectedTerminalKeyPosterFailureReturnsCancelFailure() {
        var posted = 0
        let controller = NativeTerminalController(
            keyPoster: { _ in posted += 1; return false },
            focusOverride: { _ in true },
            targetVerifier: { _ in true }
        )

        XCTAssertFalse(controller.cancel(target))
        XCTAssertEqual(posted, 1)
    }

    func testPolicyRejectsAnEventPostFailure() {
        XCTAssertFalse(NativeTerminalCancelPolicy.result(focusSucceeded: true, keyPostSucceeded: false))
    }

    func testProcessInstanceTokenBindsPidAndStartTime() {
        let start = Date(timeIntervalSince1970: 1_787_385_540.123)
        let token = NativeTerminalController.processInstanceToken(pid: 42, startTime: start)

        XCTAssertTrue(token.hasPrefix("v1:42:1787385540123:"))
        XCTAssertEqual(token.split(separator: ":").last?.count, 64)
        XCTAssertNotEqual(
            token,
            NativeTerminalController.processInstanceToken(pid: 43, startTime: start)
        )
    }

    func testInjectedTargetVerifierRejectsPidTokenReuseBeforeAction() {
        let controller = NativeTerminalController(
            keyPoster: { _ in XCTFail("key poster must not run"); return true },
            focusOverride: { _ in XCTFail("focus must not run"); return true },
            targetVerifier: { target in target.pid == 42 && target.processStartToken == "start-a" }
        )
        let reused = NativeHelperTerminalTarget(
            application: .terminal,
            pid: 42,
            processStartToken: "start-b",
            tty: "ttys012",
            cwd: "/tmp/project"
        )

        XCTAssertFalse(controller.cancel(reused))
    }

    func testCancelRevalidatesAfterFocusBeforeEscape() {
        var verificationCount = 0
        var posted = 0
        let controller = NativeTerminalController(
            keyPoster: { _ in posted += 1; return true },
            focusOverride: { _ in true },
            targetVerifier: { _ in
                verificationCount += 1
                // Initial cancel check and focus check pass. The process is
                // replaced during focus/sleep, so the action-bound check
                // fails before Terminal.app receives Escape.
                return verificationCount < 3
            }
        )

        XCTAssertFalse(controller.cancel(target))
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(verificationCount, 3)
    }

    func testSendRevalidatesAfterFocusBeforeTextWrite() {
        var verificationCount = 0
        let controller = NativeTerminalController(
            keyPoster: { _ in XCTFail("Enter must not be posted"); return true },
            focusOverride: { _ in true },
            targetVerifier: { _ in
                verificationCount += 1
                return verificationCount < 3
            }
        )

        XCTAssertFalse(controller.send("hello", to: target, submit: true))
        XCTAssertEqual(verificationCount, 3)
    }

    func testSendRevalidatesBeforeSeparateEnterAction() {
        var verificationCount = 0
        var postedKeys = 0
        let controller = NativeTerminalController(
            keyPoster: { _ in postedKeys += 1; return true },
            focusOverride: { _ in true },
            targetVerifier: { _ in
                verificationCount += 1
                // Initial send/focus/text checks pass. The process changes
                // before the second, irreversible Enter action.
                return verificationCount < 4
            }
        )

        // postText may fail before the Enter check when accessibility is not
        // available in CI. Either way, a key poster is never allowed to run
        // after the target verifier rejects the process instance.
        _ = controller.send("hello", to: target, submit: true)
        XCTAssertEqual(postedKeys, 0)
        XCTAssertGreaterThanOrEqual(verificationCount, 3)
    }

    func testPermissionModeCycleUsesExactTargetAndRevalidatesAfterPosting() {
        var posted = 0
        var verificationCount = 0
        let controller = NativeTerminalController(
            targetVerifier: { _ in
                verificationCount += 1
                return verificationCount < 2
            },
            permissionModePoster: { received in
                XCTAssertEqual(received, self.target)
                posted += 1
                return true
            }
        )

        XCTAssertFalse(controller.cyclePermissionMode(target))
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(verificationCount, 2)
    }
}
