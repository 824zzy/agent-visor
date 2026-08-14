import AppKit
import AgentVisorCore
import Combine

@MainActor
final class PillAccessibilityStatusItemController {
    static let shared = PillAccessibilityStatusItemController()

    private var statusItem: NSStatusItem?
    private var accessibilityObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var permissionCancellable: AnyCancellable?
    private var pillScreenCancellable: AnyCancellable?

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
        // The open-window affordance appears whenever the pill screen has no
        // physical notch, so re-evaluate when displays are attached/detached
        // or their arrangement changes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
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
        // The user can move the pills to a different screen at runtime, which
        // changes whether that screen has a physical notch.
        pillScreenCancellable = ScreenSelector.shared.$selectedScreen
            .sink { _ in
                Task { @MainActor in
                    PillAccessibilityStatusItemController.shared.updateStatusItem()
                }
            }
        updateStatusItem()
    }

    /// The open-window menu-bar item is shown when VoiceOver is on (its
    /// original accessibility role) or when the pill screen has no physical
    /// notch. On a notch-less external display there is no synthetic notch
    /// to click, so this item is the discoverable menu-bar path to the
    /// session browser alongside the Dock icon and the global hotkey.
    private var shouldShowOpenWindowItem: Bool {
        if NSWorkspace.shared.isVoiceOverEnabled { return true }
        if let pillScreen = ScreenSelector.shared.selectedScreen {
            return !pillScreen.hasPhysicalNotch
        }
        return false
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

        if shouldShowOpenWindowItem {
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
                button.setAccessibilityHelp("Opens the session navigator")
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
