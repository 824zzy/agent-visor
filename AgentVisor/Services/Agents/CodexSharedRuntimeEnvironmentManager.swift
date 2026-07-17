import Foundation

protocol CodexSharedRuntimeEnvironmentManaging: Sendable {
    func currentValue() async throws -> String?
    func setEnabled() async throws
    func unset() async throws
}

struct CodexSharedRuntimeEnvironmentManager: CodexSharedRuntimeEnvironmentManaging {
    static let variableName = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"

    private let processExecutor: any ProcessExecuting

    init(processExecutor: any ProcessExecuting = ProcessExecutor.shared) {
        self.processExecutor = processExecutor
    }

    func currentValue() async throws -> String? {
        let output = try await processExecutor.run(
            "/bin/launchctl",
            arguments: ["getenv", Self.variableName]
        )
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func setEnabled() async throws {
        _ = try await processExecutor.run(
            "/bin/launchctl",
            arguments: ["setenv", Self.variableName, "1"]
        )
    }

    func unset() async throws {
        _ = try await processExecutor.run(
            "/bin/launchctl",
            arguments: ["unsetenv", Self.variableName]
        )
    }
}
