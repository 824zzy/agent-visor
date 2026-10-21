import AgentVisorCore
import AppKit
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

do {
    let socketPath = try requestedSocketPath()
    try prepareSocketPath(socketPath)
    let writer = ConnectionWriter()
    NSApplication.shared.setActivationPolicy(.accessory)
    let menu = MainActor.assumeIsolated {
        let controller = NativeMenuController()
        controller.emit = { writer.send(event: $0) }
        return controller
    }
    let notifications = NativeNotificationController { writer.send(event: $0) }
    let piRestoration = MainActor.assumeIsolated { NativePiRestorationController() }
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try serve(
                socketPath: socketPath,
                menu: menu,
                notifications: notifications,
                piRestoration: piRestoration,
                writer: writer
            )
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        } catch {
            FileHandle.standardError.write(Data("AgentVisorNativeHelper: \(error)\n".utf8))
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
    NSApplication.shared.run()
} catch {
    FileHandle.standardError.write(Data("AgentVisorNativeHelper: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum HelperFailure: Error {
    case invalidArguments
    case unsafeSocketPath
    case systemCall(String, Int32)
}

private func requestedSocketPath() throws -> String {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--socket" else {
        throw HelperFailure.invalidArguments
    }
    return arguments[2]
}

private func prepareSocketPath(_ path: String) throws {
    guard path.hasPrefix("/"), path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
        throw HelperFailure.unsafeSocketPath
    }

    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
        throw HelperFailure.unsafeSocketPath
    }

    var existing = stat()
    if lstat(path, &existing) == 0 {
        guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
            throw HelperFailure.unsafeSocketPath
        }
        guard unlink(path) == 0 else { throw systemFailure("unlink") }
    } else if errno != ENOENT {
        throw systemFailure("lstat")
    }
}

private func serve(
    socketPath: String,
    menu: NativeMenuController,
    notifications: NativeNotificationController,
    piRestoration: NativePiRestorationController,
    writer: ConnectionWriter
) throws {
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw systemFailure("socket") }
    defer {
        close(listener)
        unlink(socketPath)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    socketPath.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            let bytes = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
            strncpy(bytes, source, pathCapacity - 1)
        }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { throw systemFailure("bind") }
    guard chmod(socketPath, 0o600) == 0 else { throw systemFailure("chmod") }
    guard listen(listener, 4) == 0 else { throw systemFailure("listen") }

    var client: Int32
    repeat {
        client = accept(listener, nil, nil)
    } while client < 0 && errno == EINTR
    guard client >= 0 else { throw systemFailure("accept") }
    writer.connect(client)
    handle(
        client: client,
        menu: menu,
        notifications: notifications,
        piRestoration: piRestoration,
        writer: writer
    )
    writer.disconnect(client)
    close(client)
}

private func handle(
    client: Int32,
    menu: NativeMenuController,
    notifications: NativeNotificationController,
    piRestoration: NativePiRestorationController,
    writer: ConnectionWriter
) {
    var peerUID = uid_t.max
    var peerGID = gid_t.max
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }

    var decoder = NativeHelperFrameDecoder()
    let dataPath = ProcessInfo.processInfo.environment["AGENT_VISOR_DATA_DIR"]
    let dataRoot = dataPath.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Visor")
    let ghosttyDiagnostics = NativeGhosttyViewDiagnostics(
        fileURL: dataRoot.appendingPathComponent("diagnostics/ghostty-view-read.json")
    )
    let ghostty = NativeGhosttyTerminalController(
        storageURL: dataRoot.appendingPathComponent("ghostty-terminal-evidence.json"),
        readViewText: { NativeGhosttyViewModeReader.readFooter(application: $0, title: $1, report: ghosttyDiagnostics.record) },
        nativeFocus: { target in NativeGhosttyAppleEvents(pid: target.applicationPID).focus(
            terminalID: target.terminalId, expectedTitle: target.title, expectedCWD: target.cwd) }
    )
    let ghosttyResume = NativeGhosttyResumeController()
    let ghosttyBinding = NativeGhosttyBindingController()
    let preparedGhostty = NativeGhosttyPreparedRoutes()
    var bytes = [UInt8](repeating: 0, count: 16_384)

    while true {
        let count = Darwin.read(client, &bytes, bytes.count)
        if count == 0 { return }
        if count < 0 {
            if errno == EINTR { continue }
            return
        }

        do {
            for payload in try decoder.append(bytes.prefix(count)) {
                let response = response(
                    for: payload,
                    menu: menu,
                    notifications: notifications,
                    piRestoration: piRestoration,
                    ghostty: ghostty,
                    ghosttyResume: ghosttyResume,
                    ghosttyBinding: ghosttyBinding,
                    preparedGhostty: preparedGhostty
                )
                try writer.write(try NativeHelperFrameCodec.frame(response.encoded()), to: client)
            }
        } catch {
            let response = NativeHelperResponse.error(
                id: requestID(in: Data(bytes.prefix(max(count, 0)))),
                code: .invalidRequest,
                message: "The helper request is invalid."
            )
            try? writer.write(try NativeHelperFrameCodec.frame(response.encoded()), to: client)
            return
        }
    }
}

private func response(
    for data: Data,
    menu: NativeMenuController,
    notifications: NativeNotificationController,
    piRestoration: NativePiRestorationController,
    ghostty: NativeGhosttyTerminalController,
    ghosttyResume: NativeGhosttyResumeController,
    ghosttyBinding: NativeGhosttyBindingController,
    preparedGhostty: NativeGhosttyPreparedRoutes
) -> NativeHelperResponse {
    do {
        switch try NativeHelperRequest.decode(data) {
        case .screenTopology(let id):
            return .screenTopology(id: id, screens: screenTopology())
        case .ghosttyTerminalViews(let id, let titles):
            do {
                return .ghosttyTerminalViews(id: id, views: try ghostty.views(conversationTitles: titles))
            } catch {
                return .error(id: id, code: .failed, message: "Current Ghostty terminal views could not be read.")
            }
        case .focusGhosttyTerminal(let id, let target):
            return ghostty.focus(target)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The displayed Claude conversation changed or could not be focused.")
        case .ghosttyBindingStatus(let id):
            return .ghosttyBindingStatus(id: id, available: ghosttyBinding.status())
        case .resolveGhosttyBinding(let id, let nonce):
            do {
                return .ghosttyBinding(id: id, binding: try ghosttyBinding.resolve(nonce: nonce))
            } catch {
                return .error(id: id, code: .failed, message: "The requested Ghostty surface could not be resolved.")
            }
        case .focusGhosttyBinding(let id, let target):
            do {
                try ghosttyBinding.focus(target)
                return .accepted(id: id)
            } catch {
                return .error(id: id, code: .failed, message: "The requested Ghostty surface could not be focused.")
            }
        case .prepareGhosttyBinding(let id, let target, let processes):
            return ghosttyBinding.prepare(target, processes: processes) ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The exact Herdr surface could not be prepared.")
        case .accessibilityStatus(let id):
            return .accessibilityStatus(id: id, trusted: AXIsProcessTrusted())
        case .notificationStatus(let id):
            return .notificationStatus(id: id, status: notifications.status())
        case .requestNotifications(let id):
            notifications.requestAuthorization()
            return .accepted(id: id)
        case .reconcileNotifications(let id, let values, let presentNew):
            notifications.reconcile(values, presentNew: presentNew)
            return .accepted(id: id)
        case .reconcilePiRestoration(let id, let update):
            DispatchQueue.main.sync { piRestoration.reconcile(update) }
            return .accepted(id: id)
        case .requestAccessibility(let id):
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            return .accepted(id: id)
        case .openAccessibilitySettings(let id):
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return .accepted(id: id)
        case .presentPills(
            let id,
            let pills,
            let navigatorPills,
            let usageGlances,
            let shortcutFamily,
            let pillScreen,
            let fullScreenPolicy,
            let hotkeyTrigger,
            let customHotkeyCombo
        ):
            DispatchQueue.main.sync {
                menu.present(
                    pills: pills,
                    navigatorPills: navigatorPills,
                    usageGlances: usageGlances,
                    shortcutModifierFamily: shortcutFamily,
                    pillScreen: pillScreen,
                    fullScreenPolicy: fullScreenPolicy,
                    hotkeyTrigger: hotkeyTrigger,
                    customHotkeyCombo: customHotkeyCombo
                )
            }
            return .accepted(id: id)
        case .focusTerminal(let id, let target, let conversationOnly):
            let result: Bool
            if let conversationOnly {
                result = preparedGhostty.focusOrPrepare(target, conversationOnly: conversationOnly)
            } else { result = NativeTerminalController().focus(target) }
            return result
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The requested terminal could not be focused.")
        case .prepareTerminal(let id, let target, let conversationOnly):
            return preparedGhostty.prepare(target, conversationOnly: conversationOnly) ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The exact Ghostty route could not be prepared.")
        case .openClaudeAttach(let id, let target):
            return ghostty.openClaudeAttach(target)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "Ghostty could not open the Claude background session.")
        case .openGhosttyResume(let id, let target):
            do {
                return .ghosttyResumeDispatched(id: id, dispatch: try ghosttyResume.open(target))
            } catch let error as NativeGhosttyResumeError {
                let providerName = target.provider == "codex_cli" ? "Codex" : "Claude"
                switch error {
                case .invalidTarget:
                    return .error(id: id, code: .invalidRequest, message: "The \(providerName) resume target is invalid.")
                case .permissionDenied:
                    return .error(id: id, code: .failed, message: "Ghostty Automation permission is unavailable.", reason: "activation_failed")
                case .unavailable:
                    return .error(id: id, code: .failed, message: "The existing Ghostty process is unavailable.", reason: "surface_unavailable")
                case .executableMismatch:
                    return .error(id: id, code: .failed, message: "The recorded \(providerName) executable identity changed.", reason: "executable_mismatch")
                case .profileUnavailable:
                    return .error(id: id, code: .failed, message: "The recorded \(providerName) profile is unavailable.", reason: "profile_unavailable")
                case .creationUncertain, .applicationChanged:
                    return .error(id: id, code: .failed, message: "Ghostty resume creation has an uncertain outcome.", reason: "native_creation_uncertain")
                case .malformedResponse, .surfaceUnavailable:
                    return .error(id: id, code: .failed, message: "The created Ghostty surface could not be verified.", reason: "surface_unavailable")
                }
            }
        case .readProcessProvenance(let id, let target):
            guard let identity = NativeProcessIdentityProbe.read(pid: target.pid),
                  identity.token == target.processStartToken else {
                return .processProvenance(id: id, result: .unavailable(.processMissing))
            }
            let result = NativeProcessProvenanceProbe.read(
                pid: target.pid,
                expected: target.provider,
                processStartToken: identity.token,
                homeDirectory: target.homeDirectory
            )
            return .processProvenance(id: id, result: result)
        case .sendTerminal(let id, let target, let text, let submit):
            return NativeTerminalController().send(text, to: target, submit: submit)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The terminal input could not be delivered.")
        case .cancelTerminal(let id, let target):
            return NativeTerminalController().cancel(target)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The terminal input could not be cancelled.")
        case .cyclePermissionMode(let id, let target):
            return NativeTerminalController().cyclePermissionMode(target)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The Claude permission mode could not be changed.")
        case .focus(let id, let target):
            guard target.windowId == nil else {
                return .error(
                    id: id,
                    code: .unsupported,
                    message: "Exact window focus is not enabled in this migration slice."
                )
            }
            guard let application = NSRunningApplication(processIdentifier: target.pid),
                  application.bundleIdentifier == target.bundleIdentifier else {
                return .error(id: id, code: .failed, message: "The requested process identity does not match.")
            }
            return application.activate()
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The requested application could not be focused.")
        case .openCodexThread(let id, let target):
            let result = DispatchQueue.main.sync {
                MainActor.assumeIsolated { NativeCodexThreadController.open(target) }
            }
            switch result {
            case .opened:
                return .accepted(id: id)
            case .failed(let reason, let systemCode):
                return .error(id: id, code: .failed, message: reason.message, reason: reason.rawValue, systemCode: systemCode)
            }
        }
    } catch {
        return .error(
            id: requestID(in: data),
            code: .invalidRequest,
            message: "The helper request is invalid."
        )
    }
}

private func screenTopology() -> [NativeHelperScreen] {
    NSScreen.screens.compactMap(nativeHelperScreen(for:))
}

private func requestID(in data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String,
          !id.isEmpty, id.count <= 128 else { return "invalid" }
    return id
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < data.count {
            let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw systemFailure("write")
            }
            written += count
        }
    }
}

private final class ConnectionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var client: Int32?

    func connect(_ descriptor: Int32) {
        lock.withLock { client = descriptor }
    }

    func disconnect(_ descriptor: Int32) {
        lock.withLock {
            if client == descriptor { client = nil }
        }
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try lock.withLock { try writeAll(data, to: descriptor) }
    }

    func send(event: NativeHelperEvent) {
        try? lock.withLock {
            guard let client else { return }
            try writeAll(
                try NativeHelperFrameCodec.frame(event.encoded()),
                to: client
            )
        }
    }
}

private func systemFailure(_ name: String) -> HelperFailure {
    .systemCall(name, errno)
}
