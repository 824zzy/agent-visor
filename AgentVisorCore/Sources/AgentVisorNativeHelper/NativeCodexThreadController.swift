import AgentVisorCore
import AppKit
import Foundation

enum NativeCodexThreadFailure: String, Error {
    case invalidTarget = "invalid_target"

    case processMissing = "process_missing"
    case processTerminated = "process_terminated"
    case bundleMismatch = "bundle_mismatch"
    case profileUnavailable = "profile_unavailable"
    case executableMismatch = "executable_mismatch"
    case profileAmbiguous = "profile_ambiguous"
    case profileMismatch = "profile_mismatch"
    case deepLinkRejected = "deep_link_rejected"
    case activationFailed = "activation_failed"

    var message: String {
        switch self {
        case .invalidTarget: return "The Codex session target is invalid."
        case .processMissing, .processTerminated: return "The owning Codex process is no longer running."
        case .bundleMismatch, .executableMismatch: return "The owning process no longer matches Codex."
        case .profileUnavailable: return "The native helper could not verify the owning Codex profile."
        case .profileAmbiguous: return "The owning Codex process has no verified profile."
        case .profileMismatch: return "The owning Codex process uses a different profile."
        case .deepLinkRejected: return "Codex opened, but did not select the thread. Select it in that Codex window."
        case .activationFailed: return "The owning Codex process could not be activated after its thread link failed."
        }
    }
}

enum NativeCodexThreadResult: Equatable {
    case opened
    case failed(NativeCodexThreadFailure, Int?)
}

enum NativeCodexThreadController {
    struct Application {
        let bundleIdentifier: String?
        let terminated: Bool
        let activate: () -> Bool
    }

    struct Environment {
        let application: (Int32) -> Application?
        let home: (Int32) -> Result<String, NativeCodexThreadFailure>
        let send: (Int32, URL) throws -> Void
    }

    @MainActor
    static func open(
        _ target: NativeHelperCodexThreadTarget,
        environment suppliedEnvironment: Environment? = nil
    ) -> NativeCodexThreadResult {
        guard target.isValid else { return .failed(.invalidTarget, nil) }
        let environment = suppliedEnvironment ?? liveEnvironment
        guard let app = environment.application(target.pid) else { return .failed(.processMissing, nil) }
        guard !app.terminated else { return .failed(.processTerminated, nil) }
        guard app.bundleIdentifier == "com.openai.codex" else { return .failed(.bundleMismatch, nil) }
        switch environment.home(target.pid) {
        case .failure(let reason): return .failed(reason, nil)
        case .success(let actualHome):
            guard canonical(actualHome) == canonical(target.home) else { return .failed(.profileMismatch, nil) }
        }
        guard let url = URL(string: "codex://threads/\(target.threadId)") else { return .failed(.invalidTarget, nil) }
        do {
            try environment.send(target.pid, url)
            _ = app.activate()
            return .opened
        } catch {
            let nativeError = error as NSError
            let code = nativeError.domain == NSOSStatusErrorDomain ? nativeError.code : nil
            return .failed(app.activate() ? .deepLinkRejected : .activationFailed, code)
        }
    }

    @MainActor
    private static var liveEnvironment: Environment {
        Environment(application: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return Application(bundleIdentifier: app.bundleIdentifier, terminated: app.isTerminated, activate: { app.activate() })
        }, home: home, send: send)
    }

    private static func send(_ pid: Int32, _ url: URL) throws {
        let descriptor = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: descriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        _ = try event.sendEvent(options: [.noReply], timeout: 2)
    }

    private static func home(for pid: Int32) -> Result<String, NativeCodexThreadFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", "-p", String(pid), "-o", "command="]
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.profileUnavailable) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let command = String(data: data, encoding: .utf8) else { return .failure(.profileUnavailable) }
        guard (command.contains("Codex.app/Contents/MacOS/Codex")
                || command.contains("ChatGPT.app/Contents/MacOS/ChatGPT")) else { return .failure(.executableMismatch) }
        let configured = command.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("CODEX_HOME=") }
            .map { String($0.dropFirst("CODEX_HOME=".count)) }
        if let configured { return .success(canonical(configured)) }
        if command.contains("--user-data-dir=") { return .failure(.profileAmbiguous) }
        return .success(canonical(NSHomeDirectory() + "/.codex"))
    }

    private static func canonical(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
