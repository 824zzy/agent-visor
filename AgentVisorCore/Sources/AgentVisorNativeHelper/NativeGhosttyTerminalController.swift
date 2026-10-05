import AgentVisorCore
import AppKit
import Carbon
import Darwin
import Foundation

/// Reads presentation titles without writing markers or input to any PTY.
public final class NativeGhosttyTerminalController {
    public struct ApplicationIdentity: Equatable {
        public let pid: Int32
        public let token: String
        public init(pid: Int32, token: String) { self.pid = pid; self.token = token }
    }
    private let resolveApplication: () -> ApplicationIdentity?
    private let execute: (String) -> String?
    public init(
        resolveApplication: @escaping () -> ApplicationIdentity? = NativeGhosttyTerminalController.liveApplication,
        execute: @escaping (String) -> String? = NativeGhosttyTerminalController.liveScript
    ) {
        self.resolveApplication = resolveApplication
        self.execute = execute
    }
    public func views() -> [NativeHelperGhosttyTerminalView] {
        guard let identity = resolveApplication(), let output = execute(GhosttyTerminalViewScript.list),
              let data = output.data(using: .utf8), data.count <= 512 * 1_024,
              let rows = try? JSONDecoder().decode([ViewRow].self, from: data), rows.count <= 64,
              resolveApplication() == identity else { return [] }
        let views = rows.map { NativeHelperGhosttyTerminalView(
            applicationPID: identity.pid, processStartToken: identity.token,
            terminalId: $0.terminalId, title: $0.title, cwd: $0.cwd
        ) }
        guard views.allSatisfy(\.isValid), Set(views.map(\.terminalId)).count == views.count else { return [] }
        return views
    }
    public func focus(_ target: NativeHelperGhosttyTerminalView) -> Bool {
        guard target.isValid,
              resolveApplication() == ApplicationIdentity(pid: target.applicationPID, token: target.processStartToken) else {
            return false
        }
        return execute(GhosttyTerminalViewScript.focus(target)) == "ok"
    }
    public func focusedView() -> NativeHelperGhosttyTerminalView? {
        guard let identity = resolveApplication(), let output = execute(GhosttyTerminalViewScript.focused),
              let data = output.data(using: .utf8), data.count <= 8_192,
              let row = try? JSONDecoder().decode(ViewRow.self, from: data),
              resolveApplication() == identity else { return nil }
        let view = NativeHelperGhosttyTerminalView(applicationPID: identity.pid, processStartToken: identity.token,
                                                  terminalId: row.terminalId, title: row.title, cwd: row.cwd)
        return view.isValid ? view : nil
    }
    public static func liveApplication() -> ApplicationIdentity? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.mitchellh.ghostty" && !$0.isTerminated
        }
        guard apps.count == 1, let app = apps.first,
              let token = NativeTerminalController.processStartToken(pid: app.processIdentifier) else { return nil }
        return .init(pid: app.processIdentifier, token: token)
    }

    public static func liveScript(_ source: String) -> String? {
        // Ambient discovery must not raise an Automation permission prompt.
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.mitchellh.ghostty")
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-visor-views-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let output = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? output.close() }
        let process = Process()
        let ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        if ended.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 0.25)
            }
            return nil
        }
        guard process.terminationStatus == 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1_024,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ViewRow: Decodable {
        let terminalId: String
        let title: String
        let cwd: String
    }
}
