import AppKit
import AgentVisorCore
import Combine

@MainActor
final class PillAccessibilityStatusItemController {
    static let shared = PillAccessibilityStatusItemController()

    private var statusItem: NSStatusItem?
    private var accessibilityObserver: NSObjectProtocol?
    private var permissionCancellable: AnyCancellable?

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
        permissionCancellable = PermissionHealthMonitor.shared.$health
            .removeDuplicates()
            .sink { _ in
                Task { @MainActor in
                    PillAccessibilityStatusItemController.shared.updateStatusItem()
                }
            }
        updateStatusItem()
    }

    private func updateStatusItem() {
        let presentation = PermissionHealthMonitor.shared.presentation
        if presentation.showsSetupIndicator {
            let item = ensureStatusItem(length: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle.fill",
                    accessibilityDescription: nil
                )
                button.imagePosition = .imageLeading
                button.title = "Setup"
                button.target = self
                button.action = #selector(performSetup)
                button.toolTip = "\(presentation.title): \(presentation.detail)"
                button.setAccessibilityLabel(presentation.title)
                button.setAccessibilityHelp(presentation.detail)
            }
            return
        }

        if NSWorkspace.shared.isVoiceOverEnabled {
            let item = ensureStatusItem(length: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "rectangle.stack",
                    accessibilityDescription: nil
                )
                button.imagePosition = .imageOnly
                button.title = ""
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

    private func ensureStatusItem(length: CGFloat) -> NSStatusItem {
        if let statusItem {
            statusItem.length = length
            return statusItem
        }
        let item = NSStatusBar.system.statusItem(withLength: length)
        statusItem = item
        return item
    }

    @objc private func performSetup() {
        let monitor = PermissionHealthMonitor.shared
        if PermissionSetupPolicy.primaryAction(for: monitor.health) == .requestAccessibility {
            NotchPanelRedirect.openMainWindow?()
            DispatchQueue.main.async {
                monitor.performPrimarySetupAction()
            }
            return
        }
        monitor.performPrimarySetupAction()
    }

    @objc private func openMainWindow() {
        NotchPanelRedirect.openMainWindow?()
    }
}
