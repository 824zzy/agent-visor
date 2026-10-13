import AgentVisorCore
import AppKit
import Foundation

/// Reads only; never focuses a window, sends input, or retains terminal text.
enum NativeGhosttyViewModeReader {
    static func mode(footer: String, title: String) -> NativeHelperGhosttyViewMode? {
        let lines = String(footer.suffix(4_096)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(8)
        guard let last = lines.last else { return nil }
        if last.contains("enter to return") && last.contains("space to reply") && last.contains("ctrl+x to delete") {
            return .overview
        }
        let name = title.range(of: #"^[✳◐◑] "#, options: .regularExpression) != nil ? String(title.dropFirst(2)) : title
        let caption = lines.dropLast().last(where: { $0.range(of: #"\s[—─-]+$"#, options: .regularExpression) != nil })
        guard last.hasSuffix("← for agents"), !name.isEmpty,
              let caption, caption.range(of: #"^(?:[—─-]+\s*)?"# + NSRegularExpression.escapedPattern(for: name) + #"\s+[—─-]+$"#,
                                         options: .regularExpression) != nil else {
            return nil
        }
        return .conversation
    }

    /// A unique window and a single content surface are required. Split panes,
    /// duplicate titles and unavailable Accessibility evidence stay unknown.
    static func readFooter(application: NativeGhosttyTerminalController.ApplicationIdentity, title: String) -> String? {
        guard AXIsProcessTrusted(),
              NativeGhosttyTerminalController.liveApplication() == application else { return nil }
        let root = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(root, 0.05)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 64 else { return nil }
        func sameTitle(_ value: String) -> Bool {
            let strip: (String) -> String = { value in
                value.range(of: #"^[✳◐◑] "#, options: .regularExpression) != nil ? String(value.dropFirst(2)) : value
            }
            return strip(value) == strip(title)
        }
        var matching: [AXUIElement] = []
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if let name = attribute(window, kAXTitleAttribute) as? String, sameTitle(name) { matching.append(window) }
        }
        guard matching.count == 1, let window = matching.first else { return nil }
        var pending = [window]
        var areas: [AXUIElement] = []
        var visited = 0
        while let element = pending.popLast() {
            visited += 1
            guard visited <= 256, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if (attribute(element, kAXRoleAttribute) as? String) == kAXTextAreaRole {
                areas.append(element)
                if areas.count > 1 { return nil }
            } else if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                guard children.count <= 256, pending.count + children.count <= 256 else { return nil }
                pending.append(contentsOf: children)
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, let area = areas.first,
              let text = attribute(area, kAXValueAttribute) as? String,
              text.utf16.count <= 1_048_576,
              let latestTitle = attribute(window, kAXTitleAttribute) as? String, sameTitle(latestTitle),
              NativeGhosttyTerminalController.liveApplication() == application else { return nil }
        return String(text.suffix(4_096))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
