import XCTest
@testable import AgentVisorCore

final class CodexSharedRuntimeLaunchPlanTests: XCTestCase {
    func testSocketUsesCanonicalAppServerControlPathUnderCodexHome() {
        let plan = CodexSharedRuntimeLaunchPlan(
            codexHome: "/Users/test/.codex"
        )

        XCTAssertEqual(
            plan.socketPath,
            "/Users/test/.codex/app-server-control/app-server-control.sock"
        )
    }

    func testRawServerArgumentsUseCanonicalUnixControlMode() {
        let plan = CodexSharedRuntimeLaunchPlan(
            codexHome: "/Users/test/.codex"
        )

        XCTAssertEqual(plan.rawServerArguments, [
            "-c", "features.code_mode_host=true",
            "app-server", "--listen", "unix://",
            "--analytics-default-enabled",
        ])
    }

    func testProxyArgumentsConnectToCanonicalSocket() {
        let plan = CodexSharedRuntimeLaunchPlan(
            codexHome: "/Users/test/.codex"
        )

        XCTAssertEqual(plan.proxyArguments, [
            "app-server", "proxy", "--sock",
            "/Users/test/.codex/app-server-control/app-server-control.sock",
        ])
    }

    func testHelperEnvironmentMatchesExistingLabOriginatorAndLogOverrides() {
        let plan = CodexSharedRuntimeLaunchPlan(
            codexHome: "/Users/test/.codex"
        )

        XCTAssertEqual(plan.helperEnvironmentOverrides, [
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
            "LOG_FORMAT": "json",
            "RUST_LOG": "warn",
        ])
    }

    func testFutureDesktopEnvironmentOptsIntoLocalDaemon() {
        let plan = CodexSharedRuntimeLaunchPlan(
            codexHome: "/Users/test/.codex"
        )

        XCTAssertEqual(plan.futureDesktopEnvironmentOverrides, [
            "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "1",
        ])
    }
}
