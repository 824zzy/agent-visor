import XCTest
@testable import AgentVisorCore

final class CodexDesktopRuntimeClassifierTests: XCTestCase {
    func testHealthyDaemonAloneDoesNotClassifyRunningDesktopAsShared() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: false,
                privateAppServerChildPresent: false,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: false
            )
        )

        XCTAssertEqual(runtime, .unknown)
    }

    func testDesktopAbsenceClassifiesNotRunningDespiteStaleRuntimeSignals() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: false,
                launchedAfterActivation: true,
                privateAppServerChildPresent: true,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: true
            )
        )

        XCTAssertEqual(runtime, .notRunning)
    }

    func testPrivateAppServerChildClassifiesDesktopAsPrivateRuntime() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: true,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: true
            )
        )

        XCTAssertEqual(runtime, .privateRuntime)
    }

    func testFreshDesktopLaunchWithHealthySharedRuntimeIsStartingBeforeHandshake() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: false,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: false
            )
        )

        XCTAssertEqual(runtime, .starting)
    }

    func testFreshDesktopLaunchWithHealthyRuntimeAndHandshakeIsSharedRuntime() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: false,
                sharedRuntimeSocketPresent: true,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: true
            )
        )

        XCTAssertEqual(runtime, .sharedRuntime)
    }

    func testAgentVisorHandshakeWithoutDesktopSocketRemainsStarting() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: false,
                sharedRuntimeSocketPresent: false,
                sharedRuntimeHealthy: true,
                agentVisorHandshake: true
            )
        )

        XCTAssertEqual(runtime, .starting)
    }

    func testSocketAndHandshakePreserveSharedClassificationDuringHealthProbeFailure() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: false,
                sharedRuntimeSocketPresent: true,
                sharedRuntimeHealthy: false,
                agentVisorHandshake: true
            )
        )

        XCTAssertEqual(runtime, .sharedRuntime)
    }

    func testSocketEvidencePreservesStartingClassificationDuringHealthProbeFailure() {
        let runtime = CodexDesktopRuntimeClassifier.classify(
            CodexDesktopRuntimeEvidence(
                desktopRunning: true,
                launchedAfterActivation: true,
                privateAppServerChildPresent: false,
                sharedRuntimeSocketPresent: true,
                sharedRuntimeHealthy: false,
                agentVisorHandshake: false
            )
        )

        XCTAssertEqual(runtime, .starting)
    }
}
