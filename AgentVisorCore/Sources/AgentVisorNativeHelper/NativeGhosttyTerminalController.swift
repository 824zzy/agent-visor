import AgentVisorCore
import AppKit
import Carbon
import Darwin
import Foundation

/// Reads presentation titles without writing markers or input to any PTY.
public final class NativeGhosttyTerminalController {
    public struct ApplicationIdentity: Codable, Equatable {
        public let pid: Int32
        public let token: String
        public init(pid: Int32, token: String) { self.pid = pid; self.token = token }
    }
    private let resolveApplication: () -> ApplicationIdentity?
    private let execute: (String) -> String?
    private let openAttach: (NativeHelperClaudeAttachTarget) -> String?
    private let readViewText: (ApplicationIdentity, String) -> String?
    private struct TitleEvidence: Codable, Equatable {
        let application: ApplicationIdentity
        let cwd: String
    }
    private let storageURL: URL?
    private var titleEnabledTerminals: [String: TitleEvidence] = [:]
    public init(
        storageURL: URL? = nil,
        readViewText: @escaping (ApplicationIdentity, String) -> String? = { _, _ in nil },
        resolveApplication: @escaping () -> ApplicationIdentity? = NativeGhosttyTerminalController.liveApplication,
        execute: @escaping (String) -> String? = NativeGhosttyTerminalController.liveScript,
        openAttach: @escaping (NativeHelperClaudeAttachTarget) -> String? = {
            NativeTerminalController().openClaudeAttachSurface($0)
        }
    ) {
        self.storageURL = storageURL
        self.readViewText = readViewText
        self.resolveApplication = resolveApplication
        self.execute = execute
        self.openAttach = openAttach
        if let storageURL, let input = try? FileHandle(forReadingFrom: storageURL) {
            defer { try? input.close() }
            if let data = try? input.read(upToCount: 65_537), data.count <= 65_536,
               let saved = try? JSONDecoder().decode([String: TitleEvidence].self, from: data), saved.count <= 64 {
                titleEnabledTerminals = saved.filter { id, evidence in
                    !id.isEmpty && id.utf16.count <= 128 && !id.contains("\0")
                        && evidence.application.pid > 0 && !evidence.application.token.isEmpty
                        && evidence.application.token.utf16.count <= 256 && !evidence.application.token.contains("\0")
                        && evidence.cwd.hasPrefix("/") && evidence.cwd.utf16.count <= 4_096 && !evidence.cwd.contains("\0")
                }
            }
        }
    }
    /// Trust is scoped to the created surface and this Ghostty process instance.
    public func openClaudeAttach(_ target: NativeHelperClaudeAttachTarget) -> Bool {
        let previousIdentity = resolveApplication()
        guard target.isValid,
              let terminalId = openAttach(target), !terminalId.isEmpty,
              terminalId.utf16.count <= 128, !terminalId.contains("\0"),
              let identity = resolveApplication(),
              previousIdentity == nil || previousIdentity == identity else { return false }
        titleEnabledTerminals[terminalId] = .init(application: identity, cwd: target.cwd)
        persistEvidence()
        return true
    }
    public enum ViewReadError: Error { case unreadable, invalidResponse, applicationChanged }
    public func views(conversationTitles: [String]? = nil) throws -> [NativeHelperGhosttyTerminalView] {
        guard let identity = resolveApplication() else { return [] }
        guard let output = execute(GhosttyTerminalViewScript.list) else { throw ViewReadError.unreadable }
        guard
              let data = output.data(using: .utf8), data.count <= 512 * 1_024,
              let rows = try? JSONDecoder().decode([ViewRow].self, from: data), rows.count <= 64 else {
            throw ViewReadError.invalidResponse
        }
        guard resolveApplication() == identity else { throw ViewReadError.applicationChanged }
        let currentIDs = Set(rows.map(\.terminalId))
        guard currentIDs.count == rows.count, rows.allSatisfy({ row in
            NativeHelperGhosttyTerminalView(applicationPID: identity.pid, processStartToken: identity.token,
                terminalId: row.terminalId, title: row.title, cwd: row.cwd).isValid
        }) else { throw ViewReadError.invalidResponse }
        let previous = titleEnabledTerminals
        titleEnabledTerminals = titleEnabledTerminals.filter { id, evidence in
            evidence.application == identity && rows.contains { $0.terminalId == id && $0.cwd == evidence.cwd }
        }
        let modeReadDeadline = ProcessInfo.processInfo.systemUptime + 0.4
        let allowedTitles = conversationTitles.map(Set.init)
        let views = rows.map { row in
            // Do not associate another pane/window's content with this surface.
            let name = row.title.range(of: #"^[✳◐◑] "#, options: .regularExpression) != nil
                ? String(row.title.dropFirst(2)) : row.title
            let allowed = allowedTitles?.contains(name) ?? true
            let footer = allowed && ProcessInfo.processInfo.systemUptime < modeReadDeadline
                && rows.filter({ $0.title == row.title }).count == 1
                ? readViewText(identity, row.title) : nil
            return NativeHelperGhosttyTerminalView(
                applicationPID: identity.pid, processStartToken: identity.token,
                terminalId: row.terminalId, title: row.title, cwd: row.cwd,
                titleUpdatesEnabled: titleEnabledTerminals[row.terminalId]?.application == identity ? true : nil,
                viewMode: footer.flatMap { NativeGhosttyViewModeReader.mode(footer: $0, title: row.title) }
            )
        }
        guard views.allSatisfy(\.isValid), Set(views.map(\.terminalId)).count == views.count else {
            throw ViewReadError.invalidResponse
        }
        guard resolveApplication() == identity else { throw ViewReadError.applicationChanged }
        if previous != titleEnabledTerminals { persistEvidence() }
        return views
    }
    public func focus(_ target: NativeHelperGhosttyTerminalView) -> Bool {
        guard target.isValid, target.viewMode != .overview,
              resolveApplication() == ApplicationIdentity(pid: target.applicationPID, token: target.processStartToken) else {
            return false
        }
        if target.titleUpdatesEnabled == true,
           titleEnabledTerminals[target.terminalId] != TitleEvidence(
               application: .init(pid: target.applicationPID, token: target.processStartToken), cwd: target.cwd) {
            return false
        }
        let requiresRecheck = target.viewMode == .conversation || target.titleUpdatesEnabled == true
        if requiresRecheck, !currentConversation(target) { return false }
        guard execute(GhosttyTerminalViewScript.focus(target)) == "ok" else { return false }
        return !requiresRecheck || currentConversation(target)
    }

    private func currentConversation(_ target: NativeHelperGhosttyTerminalView) -> Bool {
        let identity = ApplicationIdentity(pid: target.applicationPID, token: target.processStartToken)
        guard resolveApplication() == identity else { return false }
        let mode = readViewText(identity, target.title).flatMap {
            NativeGhosttyViewModeReader.mode(footer: $0, title: target.title)
        }
        // Surface ID, directory and normalized title are rechecked before and
        // after focus by the scripting API. Re-read only its mode here rather
        // than inspecting every terminal again inside the focus deadline.
        return mode != .overview && (target.viewMode == .conversation ? mode == .conversation : true)
    }

    private func persistEvidence() {
        guard let storageURL, let data = try? JSONEncoder().encode(titleEnabledTerminals), data.count <= 65_536 else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: storageURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch { /* Unavailable persistence cannot change live terminal evidence. */ }
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
