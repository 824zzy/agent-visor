import AppKit
import Foundation

enum CodexSharedRuntimeBinaryResolutionError: Error, Equatable, LocalizedError {
    case desktopNotFound
    case bundledBinaryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .desktopNotFound:
            return "Codex Desktop is not installed."
        case .bundledBinaryNotFound(let path):
            return "Codex Desktop's bundled codex binary is missing or not executable at \(path)."
        }
    }
}

protocol CodexSharedRuntimeBinaryResolving: Sendable {
    func bundledCodexBinaryURL() throws -> URL
}

struct CodexSharedRuntimeBinaryResolver: CodexSharedRuntimeBinaryResolving {
    typealias ApplicationURLProvider = @Sendable () -> URL?
    typealias ExecutableChecker = @Sendable (String) -> Bool

    private let applicationURLProvider: ApplicationURLProvider
    private let executableChecker: ExecutableChecker

    init(
        applicationURLProvider: @escaping ApplicationURLProvider = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        },
        executableChecker: @escaping ExecutableChecker = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.applicationURLProvider = applicationURLProvider
        self.executableChecker = executableChecker
    }

    func bundledCodexBinaryURL() throws -> URL {
        guard let appURL = applicationURLProvider() else {
            throw CodexSharedRuntimeBinaryResolutionError.desktopNotFound
        }
        let binaryURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        guard executableChecker(binaryURL.path) else {
            throw CodexSharedRuntimeBinaryResolutionError.bundledBinaryNotFound(binaryURL.path)
        }
        return binaryURL
    }
}

struct CodexSharedRuntimeHealth: Equatable, Sendable {
    let daemonStatus: String
    let appServerVersion: String
    let cliVersion: String
    let reportedSocketPath: String
    let statusRunning: Bool
    let versionsCompatible: Bool
    let socketPathMatches: Bool
    let socketExists: Bool

    var isHealthy: Bool {
        statusRunning && versionsCompatible && socketPathMatches && socketExists
    }
}

protocol CodexSharedRuntimeHealthChecking: Sendable {
    func check(expectedSocketPath: String) async throws -> CodexSharedRuntimeHealth
    func socketExists(at path: String) -> Bool
}

struct CodexSharedRuntimeHealthChecker: CodexSharedRuntimeHealthChecking {
    typealias SocketChecker = @Sendable (String) -> Bool
    typealias PathCanonicalizer = @Sendable (String) -> String

    private struct DaemonVersion: Decodable {
        let status: String
        let appServerVersion: String
        let cliVersion: String
        let socketPath: String
    }

    private let binaryResolver: any CodexSharedRuntimeBinaryResolving
    private let processExecutor: any ProcessExecuting
    private let socketChecker: SocketChecker
    private let pathCanonicalizer: PathCanonicalizer

    init(
        binaryResolver: any CodexSharedRuntimeBinaryResolving = CodexSharedRuntimeBinaryResolver(),
        processExecutor: any ProcessExecuting = ProcessExecutor.shared,
        socketChecker: @escaping SocketChecker = {
            FileManager.default.fileExists(atPath: $0)
        },
        pathCanonicalizer: @escaping PathCanonicalizer = {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
    ) {
        self.binaryResolver = binaryResolver
        self.processExecutor = processExecutor
        self.socketChecker = socketChecker
        self.pathCanonicalizer = pathCanonicalizer
    }

    func check(expectedSocketPath: String) async throws -> CodexSharedRuntimeHealth {
        let binaryURL = try binaryResolver.bundledCodexBinaryURL()
        let output = try await processExecutor.run(
            binaryURL.path,
            arguments: ["app-server", "daemon", "version"],
            timeout: 5
        )
        let version = try JSONDecoder().decode(DaemonVersion.self, from: Data(output.utf8))
        let expectedPath = pathCanonicalizer(expectedSocketPath)
        let reportedPath = pathCanonicalizer(version.socketPath)
        let cliVersion = version.cliVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let appServerVersion = version.appServerVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CodexSharedRuntimeHealth(
            daemonStatus: version.status,
            appServerVersion: version.appServerVersion,
            cliVersion: version.cliVersion,
            reportedSocketPath: version.socketPath,
            statusRunning: version.status == "running",
            versionsCompatible: !cliVersion.isEmpty && cliVersion == appServerVersion,
            socketPathMatches: !reportedPath.isEmpty && reportedPath == expectedPath,
            socketExists: socketExists(at: expectedPath)
        )
    }

    func socketExists(at path: String) -> Bool {
        socketChecker(pathCanonicalizer(path))
    }
}
