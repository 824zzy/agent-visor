import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func windows(pid: Int32) -> [CGRect] {
    let values = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return values.compactMap { value in
        guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = value[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

func click(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func find(_ element: AXUIElement, containing text: String, remaining: inout Int) -> AXUIElement? {
    guard remaining > 0 else { return nil }
    remaining -= 1
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
        if let value = attribute(element, name as CFString) as? String,
           value.localizedCaseInsensitiveContains(text) { return element }
    }
    for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
        if let match = find(child, containing: text, remaining: &remaining) { return match }
    }
    return nil
}

func labels(_ element: AXUIElement, remaining: inout Int) -> [String] {
    guard remaining > 0 else { return [] }
    remaining -= 1
    var result = [String]()
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
        let name = name as CFString
        if let value = attribute(element, name) as? String, !value.isEmpty { result.append(value) }
    }
    for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
        result.append(contentsOf: labels(child, remaining: &remaining))
    }
    return result
}

guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[2]) else { exit(2) }
let command = CommandLine.arguments[1]
let helperWindows = windows(pid: pid)
let usageWindows = helperWindows.filter {
    (60...130).contains($0.width) && (20...30).contains($0.height)
}

switch command {
case "click-usage", "double-click-usage":
    guard let panel = usageWindows.first else { exit(3) }
    let point = CGPoint(x: panel.midX, y: panel.midY)
    click(point)
    if command == "double-click-usage" {
        usleep(100_000)
        click(point)
    }
case "count-usage":
    print(usageWindows.count)
case "usage-widths":
    print(usageWindows.map { Int($0.width.rounded()) }
        .sorted().map(String.init).joined(separator: ","))
case "count-popovers":
    print(helperWindows.filter { $0.width >= 250 && $0.height > 40 }.count)
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "press-usage":
    var remaining = 1_000
    guard let element = find(
        AXUIElementCreateApplication(pid),
        containing: "Codex usage",
        remaining: &remaining
    ), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { exit(4) }
case "labels":
    var remaining = 1_000
    print(Array(Set(labels(AXUIElementCreateApplication(pid), remaining: &remaining))).sorted().joined(separator: "\n"))
default:
    exit(2)
}
