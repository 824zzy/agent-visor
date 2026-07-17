import AppKit

@MainActor
final class PillAccessibilityStatusItemController {
    static let shared = PillAccessibilityStatusItemController()

    private var statusItem: NSStatusItem?
    private var accessibilityObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PillAccessibilityStatusItemController.shared.updateStatusItem()
            }
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        if NSWorkspace.shared.isVoiceOverEnabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "rectangle.stack",
                    accessibilityDescription: nil
                )
                button.target = self
                button.action = #selector(openMainWindow)
                button.toolTip = "Open Agent Visor sessions"
                button.setAccessibilityLabel("Agent Visor sessions")
                button.setAccessibilityHelp("Opens the accessible session navigator")
            }
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func openMainWindow() {
        NotchPanelRedirect.openMainWindow?()
    }
}
