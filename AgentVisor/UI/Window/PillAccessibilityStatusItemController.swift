import AppKit
import AgentVisorCore
import Combine

/// Owns Agent Visor's menu-bar status item.
///
/// Two roles, one slot:
/// - When permissions need attention it shows the "Setup" affordance.
/// - Otherwise it is the app's menu-bar entry point to the session browser.
///
/// The entry point is unconditional. It used to appear only when VoiceOver was
/// running or when the pill display had no physical notch, because on a notched
/// display a global mouse-down monitor turned clicks over the hardware cutout
/// into window summons. That monitor is gone: it decided "this click is mine"
/// from screen geometry captured when the strip was built, so geometry left
/// over from an earlier display arrangement claimed clicks in empty space on
/// whichever display now occupies those coordinates. With the monitor removed,
/// this item — plus the Dock icon and the global hotkey — is how the session
/// browser is reached on every display.
@MainActor
final class PillAccessibilityStatusItemController {
    static let shared = PillAccessibilityStatusItemController()

    private var statusItem: NSStatusItem?
    private var permissionCancellable: AnyCancellable?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
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
            SessionBrowserRedirect.openMainWindow?()
            DispatchQueue.main.async {
                monitor.performPrimarySetupAction()
            }
            return
        }
        monitor.performPrimarySetupAction()
    }

    @objc private func openMainWindow() {
        SessionBrowserRedirect.openMainWindow?()
    }
}
