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

    /// Terminate every child currently owned by the executor and wait for its
    /// exit. Chat's serializer supplies this as the concrete production
    /// termination hook, so a timed-out lane cannot advance while an
    /// `osascript`/tmux child is still capable of writing.
    func terminateActiveProcesses(operationID: String? = nil) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                TerminalProcessOperationRegistry.shared.terminateAndWait(
                    operationID: operationID
                )
                continuation.resume()
            }
        }
    }

    /// Associate synchronous adapter work on the current utility thread with
    /// its serializer operation. This keeps a timeout/cancel scoped to one
    /// session even when a legacy adapter still calls the synchronous API.
    nonisolated static func withOperationID<Value>(
        _ operationID: String,
        _ body: () -> Value
    ) -> Value {
        let key = "AgentVisor.ProcessExecutor.operationID"
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = operationID
        defer {
            if let previous { Thread.current.threadDictionary[key] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        return body()
    }

    /// The operation identity inherited by synchronous adapter work on the
    /// current utility thread. Chat passes an explicit identity at its public
    /// seam; this read lets legacy protocol conformers forward that same
    /// identity into every child without widening their navigation API.
    nonisolated static var currentOperationID: String? {
        Thread.current.threadDictionary["AgentVisor.ProcessExecutor.operationID"] as? String
    }

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

    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        operationID: String
    ) async throws -> String {
        let result = await runWithResult(
            executable,
            arguments: arguments,
            timeout: timeout,
            operationID: operationID
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
        timeout: TimeInterval?,
        operationID: String? = nil
    ) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Self.execute(
                        executable,
                        arguments: arguments,
                        timeout: timeout,
                        operationID: operationID
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

    /// Run a synchronous command with a real child-process deadline. The
    /// timeout path terminates (and, if needed, kills) the child and waits for
    /// its termination before returning, so a serialized terminal action can
    /// safely release its lane without a late AppleScript write.
    nonisolated func runSyncWithResult(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Result<ProcessResult, ProcessExecutorError> {
        Self.execute(executable, arguments: arguments, timeout: timeout)
    }

    nonisolated func runSyncWithResult(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        operationID: String
    ) -> Result<ProcessResult, ProcessExecutorError> {
        Self.execute(
            executable,
            arguments: arguments,
            timeout: timeout,
            operationID: operationID
        )
    }

    /// Run a bounded child process with a finite stdin payload. This is used
    /// for tmux image paste, where the payload must be written before the
    /// command can exit. The same termination path as AppleScript is used on
    /// timeout, so a lane never advances while this child can still write.
    func runWithInput(
        _ executable: String,
        arguments: [String],
        input: Data,
        timeout: TimeInterval,
        operationID: String? = nil
    ) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Self.execute(
                        executable,
                        arguments: arguments,
                        timeout: timeout,
                        standardInput: input,
                        operationID: operationID
                    )
                )
            }
        }
    }

    private nonisolated static func execute(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?,
        standardInput: Data? = nil,
        operationID: String? = nil
    ) -> Result<ProcessResult, ProcessExecutorError> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }
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

        let operationID = operationID ??
            (Thread.current.threadDictionary["AgentVisor.ProcessExecutor.operationID"] as? String)
        let registrationToken = TerminalProcessOperationRegistry.shared.register(
            operationID: operationID ?? "",
            process: process,
            termination: termination
        )
        defer {
            TerminalProcessOperationRegistry.shared.unregister(registrationToken)
        }

        let capture = ProcessOutputCapture()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.setStdout(ProcessPipeReader.read(
                fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor
            ))
            readers.leave()
        }

        // Never write a potentially large stdin payload on this thread. A
        // child that does not read stdin can fill the pipe and otherwise
        // prevent us from reaching the deadline/termination path at all.
        let writer = DispatchGroup()
        if let standardInput, let stdinPipe {
            writer.enter()
            DispatchQueue.global(qos: .utility).async {
                Self.write(standardInput, to: stdinPipe.fileHandleForWriting)
                try? stdinPipe.fileHandleForWriting.close()
                writer.leave()
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.setStderr(ProcessPipeReader.read(
                fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor
            ))
            readers.leave()
        }

        // Every wait has a deadline. A child that never exits used to hold this
        // thread for the life of the app; now it becomes a missing answer, which
        // every caller already handles, because a command can also fail.
        let seconds = SubprocessDeadlinePolicy.deadline(requested: timeout)
        let timedOut = termination.wait(timeout: .now() + seconds) == .timedOut
        if timedOut {
            Self.logger.warning(
                "Gave up after \(Int(seconds))s: \(executable, privacy: .public)"
            )
            if process.isRunning { process.terminate() }
            // Closing stdin is required to unblock a writer whose child never
            // consumes its input. The writer is joined before this operation
            // returns, so it cannot continue after the lane is released.
            stdinPipe?.fileHandleForWriting.closeFile()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }

        let writerTimedOut = writer.wait(timeout: .now() + 1) == .timedOut
        if writerTimedOut {
            // A child that exited without consuming stdin may leave a
            // Foundation write blocked briefly. Close the descriptor again,
            // then give the writer one bounded chance to observe EPIPE.
            stdinPipe?.fileHandleForWriting.closeFile()
            _ = writer.wait(timeout: .now() + 1)
        }

        // A child can exit while one of its descendants keeps stdout or stderr
        // open. Draining without a deadline would then defeat the process
        // deadline above. On process timeout, close our read ends immediately;
        // otherwise allow one short drain before closing a retained pipe.
        if timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
        }
        let readerDrainTimedOut = readers.wait(timeout: .now() + 1) == .timedOut
        if readerDrainTimedOut && !timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = readers.wait(timeout: .now() + 1)
        }
        process.terminationHandler = nil

        if timedOut || writerTimedOut || readerDrainTimedOut {
            Self.logger.error("Command or output drain timed out: \(executable, privacy: .public)")
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

    private nonisolated static func write(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        // A deadline closes stdin while this writer may still be blocked. On
        // macOS, a late write to that closed pipe otherwise raises SIGPIPE
        // and can take down the whole app instead of returning EPIPE.
        _ = Darwin.fcntl(fd, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
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
