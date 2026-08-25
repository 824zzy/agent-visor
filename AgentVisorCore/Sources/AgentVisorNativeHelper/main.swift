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
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try serve(socketPath: socketPath, menu: menu, writer: writer)
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
    writer: ConnectionWriter
) throws -> Never {
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

    while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            throw systemFailure("accept")
        }
        writer.connect(client)
        handle(client: client, menu: menu, writer: writer)
        writer.disconnect(client)
        close(client)
    }
}

private func handle(
    client: Int32,
    menu: NativeMenuController,
    writer: ConnectionWriter
) {
    var peerUID = uid_t.max
    var peerGID = gid_t.max
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }

    var decoder = NativeHelperFrameDecoder()
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
                let response = response(for: payload, menu: menu)
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
    menu: NativeMenuController
) -> NativeHelperResponse {
    do {
        switch try NativeHelperRequest.decode(data) {
        case .screenTopology(let id):
            return .screenTopology(id: id, screens: screenTopology())
        case .accessibilityStatus(let id):
            return .accessibilityStatus(id: id, trusted: AXIsProcessTrusted())
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
        case .focusTerminal(let id, let target):
            return NativeTerminalController().focus(target)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The requested terminal could not be focused.")
        case .sendTerminal(let id, let target, let text, let submit):
            return NativeTerminalController().send(text, to: target, submit: submit)
                ? .accepted(id: id)
                : .error(id: id, code: .failed, message: "The terminal input could not be delivered.")
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
    NSScreen.screens.compactMap { screen in
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? UInt32 else { return nil }
        return NativeHelperScreen(
            displayId: displayID,
            name: screen.localizedName,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            frame: rectangle(screen.frame),
            visibleFrame: rectangle(screen.visibleFrame),
            scale: screen.backingScaleFactor,
            isMain: screen == NSScreen.main
        )
    }
}

private func rectangle(_ value: NSRect) -> NativeHelperRectangle {
    NativeHelperRectangle(
        x: value.origin.x,
        y: value.origin.y,
        width: value.width,
        height: value.height
    )
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
