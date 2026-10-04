import AgentVisorCore
@testable import AgentVisorNativeHelper
import XCTest

final class NativeCodexThreadControllerTests: XCTestCase {
    @MainActor
    func testInvalidTargetIsReportedWithoutOpeningAnApplication() {
        let target = NativeHelperCodexThreadTarget(pid: 0, home: "/home", threadId: "invalid")
        XCTAssertEqual(NativeCodexThreadController.open(target), .failed(.invalidTarget, nil))
    }

    @MainActor
    func testProcessAndProfileRejectionsRemainDistinctAndDoNotSendADeepLink() {
        let target = NativeHelperCodexThreadTarget(
            pid: 7, home: "/Users/me/.codex",
            threadId: "01a063f4-9a1e-7743-8368-65d01d3107af"
        )
        var application: NativeCodexThreadController.Application? = nil
        var profile: Result<String, NativeCodexThreadFailure> = .failure(.profileUnavailable)
        var sends = 0
        let environment = NativeCodexThreadController.Environment(
            application: { _ in application }, home: { _ in profile },
            send: { _, _ in sends += 1 }
        )
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.processMissing, nil))
        application = .init(bundleIdentifier: "com.openai.codex", terminated: false, activate: { true })
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.profileUnavailable, nil))
        profile = .success("/Users/me/.codex-other")
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.profileMismatch, nil))
        application = .init(bundleIdentifier: "another.application", terminated: false, activate: { true })
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.bundleMismatch, nil))
        XCTAssertEqual(sends, 0)
    }

    @MainActor
    func testDeepLinkFailureKeepsTheSystemCodeAndDoesNotClaimTheThreadOpened() {
        let target = NativeHelperCodexThreadTarget(
            pid: 7, home: "/Users/me/.codex",
            threadId: "01a063f4-9a1e-7743-8368-65d01d3107af"
        )
        var canActivate = true
        var fails = true
        let environment = NativeCodexThreadController.Environment(
            application: { _ in .init(bundleIdentifier: "com.openai.codex", terminated: false, activate: { canActivate }) },
            home: { _ in .success("/Users/me/.codex") },
            send: { _, url in
                XCTAssertEqual(url.absoluteString, "codex://threads/01a063f4-9a1e-7743-8368-65d01d3107af")
                if fails { throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
            }
        )
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.deepLinkRejected, -1743))
        canActivate = false
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .failed(.activationFailed, -1743))
        fails = false
        XCTAssertEqual(NativeCodexThreadController.open(target, environment: environment), .opened)
    }
}
