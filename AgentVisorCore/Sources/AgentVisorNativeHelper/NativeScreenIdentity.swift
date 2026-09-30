import AgentVisorCore
import AppKit

func nativeDisplayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

/// The display UUID is stable per monitor. CGDirectDisplayID is not: macOS can
/// give a home monitor and an office monitor the same ID.
func nativeDisplayUUID(of displayID: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, uuid) as String?
}

func nativeHelperScreen(for screen: NSScreen) -> NativeHelperScreen? {
    guard let displayID = nativeDisplayID(of: screen) else { return nil }
    return NativeHelperScreen(
        displayId: displayID,
        displayUuid: nativeDisplayUUID(of: displayID),
        name: screen.localizedName,
        isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
        frame: NativeHelperRectangle(screen.frame),
        visibleFrame: NativeHelperRectangle(screen.visibleFrame),
        scale: screen.backingScaleFactor,
        isMain: screen == NSScreen.main
    )
}

private extension NativeHelperRectangle {
    init(_ value: CGRect) {
        self.init(x: value.origin.x, y: value.origin.y, width: value.width, height: value.height)
    }
}
