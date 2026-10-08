import Darwin
import Foundation

/// Runs short commands with small output, preserving each caller's deadline.
/// Owns pipe closure even when the long-lived helper thread never drains its pool.
enum NativeCommandRunner {
    struct Result {
        let status: Int32
        let output: Data
    }

    static func run(
        _ executable: String,
        arguments: [String],
        captureOutput: Bool = true,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.25
    ) -> Result? {
        let process = Process()
        let output = captureOutput ? Pipe() : nil
        defer {
            try? output?.fileHandleForReading.close()
            try? output?.fileHandleForWriting.close()
        }
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + terminationGrace)
            }
            return nil
        }
        return Result(
            status: process.terminationStatus,
            output: output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        )
    }
}
