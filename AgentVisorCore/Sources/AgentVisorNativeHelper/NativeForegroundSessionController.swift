import AgentVisorCore
import AppKit
import Foundation

/// Read only the focused surface's identity. Never inspect transcript text,
/// sidebar links, background windows, or raise an access permission prompt.
enum NativeForegroundSessionController {
    static func view() -> NativeHelperForegroundSessionView? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        let startedAt = app.launchDate
        let observedAt = Date().formatted(.iso8601)
        let result: NativeHelperForegroundSessionView?
        switch app.bundleIdentifier {
        case "com.mitchellh.ghostty":
            guard let terminal = NativeGhosttyTerminalController().focusedView(),
                  terminal.applicationPID == pid else { return nil }
            result = .init(source: "ghostty", terminal: terminal, observedAt: observedAt)
        case "com.openai.codex":
            guard AXIsProcessTrusted(), let threadId = focusedCodexThread(pid) else { return nil }
            result = .init(source: "codex", pid: pid, threadId: threadId, observedAt: observedAt)
        default: return nil
        }
        guard let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier == pid, current.launchDate == startedAt, !current.isTerminated else { return nil }
        return result
    }

    private static func focusedCodexThread(_ pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let value = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        var pending: [AXUIElement] = [window]
        var ids = Set<String>()
        let deadline = Date().addingTimeInterval(0.3)
        var count = 0
        while let element = pending.popLast(), count < 128, Date() < deadline {
            count += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            // Only the document/web area URL identifies a selected chat.
            // Link URLs inside a sidebar must never acknowledge those chats.
            if role == kAXWindowRole || role == "AXWebArea" {
                for key in [kAXDocumentAttribute, "AXURL"] {
                    if let value = attribute(element, key),
                       let id = CodexFocusedConversationURL.threadId(String(describing: value)) {
                        ids.insert(id)
                    }
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(128 - count))
            }
        }
        guard ids.count == 1 else { return nil }
        return ids.first
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
