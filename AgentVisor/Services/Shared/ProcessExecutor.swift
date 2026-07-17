//
//  ProcessExecutor.swift
//  AgentVisor
//
//  Shared utility for executing shell commands with proper error handling
//

import Darwin
import AgentVisorCore
import Foundation
import os.log

/// Errors that can occur during process execution
enum ProcessExecutorError: Error, LocalizedError, Sendable {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, message: String)
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let command, let exitCode, let stderr):
            let stderrInfo = stderr.map { ", stderr: \($0)" } ?? ""
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrInfo)"
        case .invalidOutput(let command):
            return "Command '\(command)' produced invalid output"
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        case .launchFailed(let command, let message):
            return "Failed to launch '\(command)': \(message)"
        case .timedOut(let command):
            return "Command '\(command)' timed out"
        }
    }
}

/// Result type for process execution
struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stderr: String?

    nonisolated var isSuccess: Bool { exitCode == 0 }
}

/// Protocol for executing shell commands (enables testing)
protocol ProcessExecuting: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> String
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError>
    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError>
    func runSyncWithResult(_ executable: String, arguments: [String]) -> Result<ProcessResult, ProcessExecutorError>
}

extension ProcessExecuting {
    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await run(executable, arguments: arguments)
    }
}

/// Default implementation using Foundation.Process
nonisolated final class ProcessExecutor: @unchecked Sendable, ProcessExecuting {
    /// Shared instance for command execution.
    nonisolated static let shared = ProcessExecutor()

    /// Logger for process execution (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ProcessExecutor")

    private init() {}

    /// Run a command asynchronously and return output (throws on failure)
    func run(_ executable: String, arguments: [String]) async throws -> String {
        let result = await runWithResult(executable, arguments: arguments)
        return try Self.output(from: result, command: executable)
    }

    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let result = await runWithResult(
            executable,
            arguments: arguments,
            timeout: timeout
        )
        return try Self.output(from: result, command: executable)
    }

    private static func output(
        from result: Result<ProcessResult, ProcessExecutorError>,
        command: String
    ) throws -> String {
        switch result {
        case .success(let processResult):
            guard processResult.isSuccess else {
                Self.logger.warning(
                    "Command failed: \(command, privacy: .public) - exit code \(processResult.exitCode)"
                )
                throw ProcessExecutorError.executionFailed(
                    command: command,
                    exitCode: processResult.exitCode,
                    stderr: processResult.stderr
                )
            }
            return processResult.output
        case .failure(let error):
            throw error
        }
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        await runWithResult(executable, arguments: arguments, timeout: nil)
    }

    private func runWithResult(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Self.execute(
                        executable,
                        arguments: arguments,
                        timeout: timeout
                    )
                )
            }
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    nonisolated func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        switch Self.execute(executable, arguments: arguments, timeout: nil) {
        case .success(let result):
            guard result.isSuccess else {
                Self.logger.warning(
                    "Command failed: \(executable) \(arguments.joined(separator: " "), privacy: .public) - exit code \(result.exitCode)"
                )
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: result.exitCode,
                    stderr: result.stderr
                ))
            }
            return .success(result.output)
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated func runSyncWithResult(
        _ executable: String,
        arguments: [String]
    ) -> Result<ProcessResult, ProcessExecutorError> {
        Self.execute(executable, arguments: arguments, timeout: nil)
    }

    private nonisolated static func execute(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) -> Result<ProcessResult, ProcessExecutorError> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            }
            Self.logger.error(
                "Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)"
            )
            return .failure(.launchFailed(
                command: executable,
                message: error.localizedDescription
            ))
        } catch {
            Self.logger.error(
                "Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)"
            )
            return .failure(.launchFailed(
                command: executable,
                message: error.localizedDescription
            ))
        }

        let capture = ProcessOutputCapture()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
        let timedOut = termination.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }
        readers.wait()
        process.terminationHandler = nil

        if timedOut {
            Self.logger.error("Command timed out: \(executable, privacy: .public)")
            return .failure(.timedOut(command: executable))
        }

        let stdout = String(data: capture.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: capture.stderr, encoding: .utf8)
        let result = ProcessResult(
            output: stdout,
            exitCode: process.terminationStatus,
            stderr: stderr
        )
        if process.terminationStatus == 0 {
            return .success(result)
        }

        return .success(result)
    }
}

nonisolated private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    var stdout: Data {
        lock.withLock { stdoutData }
    }

    var stderr: Data {
        lock.withLock { stderrData }
    }

    func setStdout(_ data: Data) {
        lock.withLock { stdoutData = data }
    }

    func setStderr(_ data: Data) {
        lock.withLock { stderrData = data }
    }
}

// MARK: - Convenience Extensions

extension ProcessExecutor {
    /// Run a command and return output, returning nil only if the command itself fails to execute
    /// (as opposed to non-zero exit codes which may still have useful output)
    func runOrNil(_ executable: String, arguments: [String]) async -> String? {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let processResult):
            return processResult.output
        case .failure:
            return nil
        }
    }

    /// Run a command synchronously, returning nil on failure (backwards compatible)
    nonisolated func runSyncOrNil(_ executable: String, arguments: [String]) -> String? {
        switch runSync(executable, arguments: arguments) {
        case .success(let output):
            return output
        case .failure:
            return nil
        }
    }
}
