import AgentVisorCore
import AppKit
import Foundation

enum NativeCodexThreadResult {
    case opened
    case focused
    case unavailable
}

enum NativeCodexThreadController {
    @MainActor
    static func open(_ target: NativeHelperCodexThreadTarget) -> NativeCodexThreadResult {
        guard target.isValid,
              let app = NSRunningApplication(processIdentifier: target.pid),
              !app.isTerminated,
              app.bundleIdentifier == "com.openai.codex",
              let actualHome = home(for: target.pid),
              actualHome == canonical(target.home),
              let url = URL(string: "codex://threads/\(target.threadId)") else {
            return .unavailable
        }
        let descriptor = NSAppleEventDescriptor(processIdentifier: target.pid)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: descriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 2)
            _ = app.activate()
            return .opened
        } catch {
            return app.activate() ? .focused : .unavailable
        }
    }

    private static func home(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", "-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let command = String(data: data, encoding: .utf8),
              (command.contains("Codex.app/Contents/MacOS/Codex")
                || command.contains("ChatGPT.app/Contents/MacOS/ChatGPT")) else { return nil }
        let configured = command.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("CODEX_HOME=") }
            .map { String($0.dropFirst("CODEX_HOME=".count)) }
        if let configured { return canonical(configured) }
        if command.contains("--user-data-dir=") { return nil }
        return canonical(NSHomeDirectory() + "/.codex")
    }

    private static func canonical(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
