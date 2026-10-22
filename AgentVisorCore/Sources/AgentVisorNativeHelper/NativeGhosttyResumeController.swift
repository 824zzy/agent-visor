import AgentVisorCore
import AppKit
import Foundation

public enum NativeGhosttyResumeError: Error, Equatable {
    case invalidTarget
    case permissionDenied
    case preCreationFailed
    case unavailable
    case executableMismatch
    case profileUnavailable
    case creationUncertain
    case applicationChanged
    case malformedResponse
    case surfaceUnavailable
}

/// Creates one exact Claude resume surface in the already-running Ghostty
/// process. It returns a receipt only after the created terminal's native
/// identity and working directory have been read back.
public final class NativeGhosttyResumeController {
    private struct LaunchResult: Decodable {
        let status: String
        let reason: String?
        let windowId: String?
        let tabId: String?
        let terminalId: String?
    }

    private let resolveApplication: () -> NativeGhosttyTerminalController.ApplicationIdentity?
    private let execute: (String) -> String?
    private let permission: () -> Bool
    private let launchApplication: () -> Bool
    private let readSurface: (Int32, String) -> NativeGhosttyAppleEvents.Surface?
    private let homeDirectory: String

    public init(
        resolveApplication: @escaping () -> NativeGhosttyTerminalController.ApplicationIdentity? =
            NativeGhosttyTerminalController.liveApplication,
        execute: @escaping (String) -> String? = NativeGhosttyTerminalController.liveScript,
        permission: @escaping () -> Bool = NativeGhosttyBindingController.liveAutomationPermission,
        launchApplication: @escaping () -> Bool = NativeGhosttyResumeController.liveLaunchApplication,
        readSurface: ((Int32, String) -> NativeGhosttyAppleEvents.Surface?)? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.resolveApplication = resolveApplication
        self.execute = execute
        self.permission = permission
        self.launchApplication = launchApplication
        self.readSurface = readSurface ?? { pid, terminalID in
            NativeGhosttyAppleEvents(pid: pid).surface(id: terminalID)
        }
        self.homeDirectory = homeDirectory
    }

    public func open(_ target: NativeHelperGhosttyResumeTarget) throws -> NativeHelperGhosttyResumeDispatch {
        guard target.isValid, target.profileState == "present" || target.profileState == "verified_absent",
              isDirectory(target.cwd), isTrustedExecutable(target.executable),
              (target.configRoot.map(isDirectory) ?? true),
              (target.settingsFile.map(isRegularFile) ?? true),
              homeDirectory.hasPrefix("/") else {
            throw NativeGhosttyResumeError.invalidTarget
        }
        if target.provider == "codex_cli" {
            guard let configRoot = target.configRoot, isDirectory(configRoot),
                  URL(fileURLWithPath: configRoot).resolvingSymlinksInPath().path == configRoot,
                  target.settingsFile == nil, target.settingSources == nil,
                  target.profileState == "verified_absent" || target.profileRef != nil else {
                throw NativeGhosttyResumeError.invalidTarget
            }
            if target.profileState == "present",
               let profile = target.profileRef,
               !isRegularFile((configRoot as NSString).appendingPathComponent("\(profile).config.toml")) {
                throw NativeGhosttyResumeError.profileUnavailable
            }
        }
        guard permission() else { throw NativeGhosttyResumeError.permissionDenied }
        let application: NativeGhosttyTerminalController.ApplicationIdentity
        if let existing = resolveApplication() {
            application = existing
        } else {
            // Ghostty may be installed but quit. Launch its canonical bundle
            // through NSWorkspace and then resolve one fresh process identity;
            // never use `open -n` or a second app instance as a route.
            guard launchApplication(), let launched = waitForApplication() else {
                throw NativeGhosttyResumeError.preCreationFailed
            }
            application = launched
        }

        let script = target.provider == "codex_cli"
            ? CodexGhosttyResumeScript.make(target: target, homeDirectory: homeDirectory)
            : ClaudeGhosttyResumeScript.make(target: target, homeDirectory: homeDirectory)
        guard let output = execute(script) else {
            // The script may have created a surface before the bounded helper
            // read timed out. Never retry this attempt from an uncertain call.
            throw NativeGhosttyResumeError.creationUncertain
        }
        guard resolveApplication() == application else {
            throw NativeGhosttyResumeError.applicationChanged
        }
        guard output.utf8.count <= 16 * 1_024,
              let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(LaunchResult.self, from: data) else {
            throw NativeGhosttyResumeError.creationUncertain
        }
        guard result.status == "created" else {
            if result.status == "pre_creation_failed" { throw NativeGhosttyResumeError.preCreationFailed }
            if result.status == "unavailable" { throw NativeGhosttyResumeError.unavailable }
            throw NativeGhosttyResumeError.creationUncertain
        }
        guard let windowID = result.windowId, let tabID = result.tabId,
              let terminalID = result.terminalId,
              Self.validOpaque(windowID), Self.validOpaque(tabID), Self.validOpaque(terminalID),
              let surface = readSurface(application.pid, terminalID),
              surface.id == terminalID, surface.cwd == target.cwd,
              resolveApplication() == application else {
            throw NativeGhosttyResumeError.surfaceUnavailable
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dispatch = NativeHelperGhosttyResumeDispatch(
            attemptId: target.attemptId,
            provider: target.provider,
            sessionId: target.sessionId,
            applicationPID: application.pid,
            processStartToken: application.token,
            windowId: windowID,
            tabId: tabID,
            terminalId: terminalID,
            nonce: target.nonce,
            dispatchedAt: formatter.string(from: Date())
        )
        guard dispatch.isValid else { throw NativeGhosttyResumeError.malformedResponse }
        return dispatch
    }

    private func waitForApplication() -> NativeGhosttyTerminalController.ApplicationIdentity? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let application = resolveApplication() { return application }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        } while Date() < deadline
        return resolveApplication()
    }

    public static func liveLaunchApplication() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty"),
              Bundle(url: url)?.bundleIdentifier == "com.mitchellh.ghostty" else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    private func isTrustedExecutable(_ path: String) -> Bool {
        guard isRegularFile(path), FileManager.default.isExecutableFile(atPath: path) else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }

    private func isRegularFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private static func validOpaque(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.contains("\0")
    }
}
