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

func screen(containing frame: CGRect) -> NSScreen? {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.first { screen in
        let appKitFrame = screen.frame
        let cgFrame = CGRect(
            x: appKitFrame.minX,
            y: primaryHeight - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
        return cgFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

func displayID(containing frame: CGRect) -> UInt32? {
    screen(containing: frame)?
        .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
}

func usageAlphas(pid: Int32) -> [Double] {
    let values = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return values.compactMap { value in
        guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = value[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              (60...130).contains(frame.width), (20...30).contains(frame.height) else { return nil }
        return (value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
    }
}

func move(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGEvent(
        mouseEventSource: CGEventSource(stateID: .hidSystemState),
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
}

func postModifier(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(30_000)
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
case "usage-display-ids":
    print(usageWindows.compactMap(displayID).sorted().map(String.init).joined(separator: ","))
case "usage-visible":
    print(usageAlphas(pid: pid).contains(where: { $0 > 0.01 }))
case "move-top", "move-away":
    guard let frame = usageWindows.first,
          let screen = screen(containing: frame) else { exit(3) }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let cgScreen = CGRect(
        x: screen.frame.minX,
        y: primaryHeight - screen.frame.maxY,
        width: screen.frame.width,
        height: screen.frame.height
    )
    move(command == "move-top"
        ? CGPoint(x: cgScreen.midX, y: cgScreen.minY + 1)
        : CGPoint(x: cgScreen.midX, y: cgScreen.midY))
case "shortcut-down":
    postModifier(keyCode: 58, down: true, flags: .maskAlternate)
    postModifier(keyCode: 55, down: true, flags: [.maskAlternate, .maskCommand])
case "shortcut-up":
    postModifier(keyCode: 55, down: false, flags: .maskAlternate)
    postModifier(keyCode: 58, down: false, flags: [])
case "shortcut-one":
    postModifier(keyCode: 18, down: true, flags: [.maskAlternate, .maskCommand])
    postModifier(keyCode: 18, down: false, flags: [.maskAlternate, .maskCommand])
    postModifier(keyCode: 55, down: false, flags: .maskAlternate)
    postModifier(keyCode: 58, down: false, flags: [])
case "shortcut-zero":
    postModifier(keyCode: 29, down: true, flags: [.maskAlternate, .maskCommand])
    postModifier(keyCode: 29, down: false, flags: [.maskAlternate, .maskCommand])
    postModifier(keyCode: 55, down: false, flags: .maskAlternate)
    postModifier(keyCode: 58, down: false, flags: [])
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
