import AppKit
import ApplicationServices
import Darwin

public enum FullScreenWindowDetector {
    public nonisolated static func ownerPID(
        intersecting screenRect: CGRect,
        excluding excludedPID: pid_t = getpid()
    ) -> pid_t? {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != excludedPID
        }
        for application in applications {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
            let windows = windowsValue as? [AXUIElement] else { continue }
            for window in windows {
                var fullScreenValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    window,
                    "AXFullScreen" as CFString,
                    &fullScreenValue
                ) == .success,
                (fullScreenValue as? Bool) == true else { continue }

                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(
                    window,
                    kAXPositionAttribute as CFString,
                    &positionValue
                )
                _ = AXUIElementCopyAttributeValue(
                    window,
                    kAXSizeAttribute as CFString,
                    &sizeValue
                )
                var position = CGPoint.zero
                var size = CGSize.zero
                if let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID() {
                    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                }
                if let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }
                let frame = CGRect(origin: position, size: size)
                if screenRect.intersects(frame) || frame == .zero {
                    return application.processIdentifier
                }
            }
        }
        return nil
    }
}
