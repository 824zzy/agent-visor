import AppKit
import ApplicationServices

/// Identifies the application menu retained by a display, even when focus is elsewhere.
enum NativeMenuOwnerProbe {
    struct Hit {
        let pid: pid_t
        let role: String
    }

    static func ownerPID(on screenRect: CGRect) -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let pid = ownerPID(on: screenRect, hitTest: { point in
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
                == .success, let element else { return nil }
            var pid: pid_t = 0
            var role: CFTypeRef?
            guard AXUIElementGetPid(element, &pid) == .success,
                  AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                    == .success, let role = role as? String else { return nil }
            // Inactive menu bars may report the active display's frame. The hit-test
            // point, menu role and PID identify the local owner; its frame does not.
            return Hit(pid: pid, role: role)
        }), pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              !(app.bundleIdentifier?.isEmpty ?? true) else { return nil }
        return pid
    }

    static func ownerPID(on screenRect: CGRect, hitTest: (CGPoint) -> Hit?) -> pid_t? {
        guard [screenRect.minX, screenRect.minY, screenRect.width, screenRect.height]
            .allSatisfy(\.isFinite), screenRect.width > 60, screenRect.height > 18 else { return nil }
        guard let appleMenu = hitTest(CGPoint(x: screenRect.minX + 20, y: screenRect.minY + 18)),
              let applicationMenu = hitTest(CGPoint(x: screenRect.minX + 60, y: screenRect.minY + 18)),
              appleMenu.pid > 0, appleMenu.pid == applicationMenu.pid,
              isApplicationMenu(appleMenu), isApplicationMenu(applicationMenu) else { return nil }
        return appleMenu.pid
    }

    private static func isApplicationMenu(_ hit: Hit) -> Bool {
        hit.role == kAXMenuBarRole as String || hit.role == kAXMenuBarItemRole as String
    }
}
