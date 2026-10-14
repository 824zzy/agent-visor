import AgentVisorCore
import AppKit
import Foundation

/// Reads only; never focuses a window, sends input, or retains terminal text.
enum NativeGhosttyViewModeReader {
    static func mode(footer: String, title: String) -> NativeHelperGhosttyViewMode? {
        let content = String(footer.suffix(4_096)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var lines = content.suffix(8)
        // Claude's expanded child panel follows the conversation footer. Peel
        // only a bounded panel with its main row and timed child rows, then
        // apply the same current-caption and footer checks as a plain view.
        if let main = content.lastIndex(where: { $0.range(of: #"^[●•○◯] main$"#, options: .regularExpression) != nil }) {
            let children = content.suffix(from: main + 1)
            let childRow = #"^[●•○◯] [A-Za-z0-9][A-Za-z0-9_.:-]*\s+.*\b[0-9]+(?:ms|s|m|h)(?:\s*[0-9]+(?:s|m))?(?:\s+·\s+.*)?$"#
            if !children.isEmpty, children.count <= 32,
               children.allSatisfy({ $0.range(of: childRow, options: .regularExpression) != nil }) {
                lines = content.prefix(upTo: main).suffix(8)
            }
        }
        guard let last = lines.last else { return nil }
        if last.contains("enter to return") && last.contains("space to reply") && last.contains("ctrl+x to delete") {
            return .overview
        }
        let name = title.range(of: #"^[✳◐◑] "#, options: .regularExpression) != nil ? String(title.dropFirst(2)) : title
        let caption = lines.dropLast().last(where: { $0.range(of: #"\s[—─-]+$"#, options: .regularExpression) != nil })
        // Claude replaces the hint with a bounded agent/completion count when
        // background jobs exist. The exact current caption is still required.
        let agentHint = #"← (?:for agents|(?:[1-9][0-9]?|99\+) (?:agents?|done))$"#
        guard last.range(of: agentHint, options: .regularExpression) != nil, !name.isEmpty,
              let caption, caption.range(of: #"^(?:[—─-]+\s*)?"# + NSRegularExpression.escapedPattern(for: name) + #"\s+[—─-]+$"#,
                                         options: .regularExpression) != nil else {
            return nil
        }
        return .conversation
    }

    /// A unique window and a single content surface are required. Split panes,
    /// duplicate titles and unavailable Accessibility evidence stay unknown.
    static func readFooter(application: NativeGhosttyTerminalController.ApplicationIdentity, title: String,
                           report: (NativeGhosttyViewReadReport) -> Void = { _ in }) -> String? {
        var observation = NativeGhosttyViewReadReport(reason: .accessibilityNeeded)
        var footer: String?
        defer {
            if let footer {
                switch mode(footer: footer, title: title) {
                case .conversation: observation.reason = .conversation
                case .overview: observation.reason = .overview
                case nil: observation.reason = .unsupportedFooter
                }
            }
            report(observation)
        }
        guard AXIsProcessTrusted() else { return nil }
        observation.reason = .applicationChanged
        guard NativeGhosttyTerminalController.liveApplication() == application else { return nil }
        let root = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(root, 0.05)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        observation.reason = .windowsUnavailable
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 64 else { return nil }
        observation.windows = windows.count
        func sameTitle(_ value: String) -> Bool {
            let strip: (String) -> String = { value in
                value.range(of: #"^[✳◐◑] "#, options: .regularExpression) != nil ? String(value.dropFirst(2)) : value
            }
            return strip(value) == strip(title)
        }
        var matching: [AXUIElement] = []
        for window in windows {
            observation.reason = .deadline
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if let name = attribute(window, kAXTitleAttribute) as? String, sameTitle(name) { matching.append(window) }
        }
        observation.matchingWindows = matching.count
        observation.reason = matching.isEmpty ? .windowNotFound : .windowAmbiguous
        guard matching.count == 1, let window = matching.first else { return nil }
        var pending = [window]
        var areas: [AXUIElement] = []
        var visited = 0
        while let element = pending.popLast() {
            visited += 1
            observation.elements = min(256, visited)
            observation.reason = .traversalLimit
            guard visited <= 256 else { return nil }
            observation.reason = .deadline
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if (attribute(element, kAXRoleAttribute) as? String) == kAXTextAreaRole {
                areas.append(element)
                observation.textAreas = areas.count
                observation.reason = .textAreaAmbiguous
                if areas.count > 1 { return nil }
            } else if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                observation.reason = .traversalLimit
                guard children.count <= 256, pending.count + children.count <= 256 else { return nil }
                pending.append(contentsOf: children)
            }
        }
        observation.reason = .deadline
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        observation.reason = .textAreaMissing
        guard let area = areas.first else { return nil }
        observation.reason = .textUnavailable
        guard let text = attribute(area, kAXValueAttribute) as? String else { return nil }
        observation.reason = .textTooLarge
        guard text.utf16.count <= 1_048_576 else { return nil }
        observation.reason = .titleChanged
        guard let latestTitle = attribute(window, kAXTitleAttribute) as? String, sameTitle(latestTitle) else { return nil }
        observation.reason = .applicationChanged
        guard NativeGhosttyTerminalController.liveApplication() == application else { return nil }
        footer = String(text.suffix(4_096))
        return footer
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
