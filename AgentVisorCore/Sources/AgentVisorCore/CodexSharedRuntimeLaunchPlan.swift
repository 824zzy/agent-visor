import Foundation

public struct CodexSharedRuntimeLaunchPlan: Equatable, Sendable {
    public let socketPath: String
    public let rawServerArguments: [String]
    public let proxyArguments: [String]
    public let helperEnvironmentOverrides: [String: String]
    public let futureDesktopEnvironmentOverrides: [String: String]

    public init(codexHome: String) {
        let socketPath = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock", isDirectory: false)
            .path
        self.socketPath = socketPath
        rawServerArguments = [
            "-c", "features.code_mode_host=true",
            "app-server", "--listen", "unix://",
            "--analytics-default-enabled",
        ]
        proxyArguments = ["app-server", "proxy", "--sock", socketPath]
        helperEnvironmentOverrides = [
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
            "LOG_FORMAT": "json",
            "RUST_LOG": "warn",
        ]
        futureDesktopEnvironmentOverrides = [
            "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "1",
        ]
    }
}
