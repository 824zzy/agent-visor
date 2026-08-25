import AppKit
import Foundation

func displayID(_ screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

guard CommandLine.arguments.count == 2,
      let requestedID = UInt32(CommandLine.arguments[1]),
      let screen = NSScreen.screens.first(where: { displayID($0) == requestedID }) else {
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: screen.visibleFrame,
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false,
    screen: screen
)
window.title = "Agent Visor Full-Screen Test Host"
window.collectionBehavior = [.fullScreenPrimary]
window.makeKeyAndOrderFront(nil)
app.activate()

let observer = NotificationCenter.default.addObserver(
    forName: NSWindow.didEnterFullScreenNotification,
    object: window,
    queue: .main
) { _ in
    FileHandle.standardOutput.write(Data("READY\n".utf8))
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    window.toggleFullScreen(nil)
}
app.run()
NotificationCenter.default.removeObserver(observer)
