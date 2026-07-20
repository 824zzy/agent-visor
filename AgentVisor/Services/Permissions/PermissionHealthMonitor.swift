import AppKit
import ApplicationServices
import AgentVisorCore
import Combine
import os.log

extension Notification.Name {
    static let agentVisorAccessibilityRecovered = Notification.Name(
        "AgentVisor.accessibilityRecovered"
    )
}

@MainActor
final class PermissionHealthMonitor: ObservableObject {
    static let shared = PermissionHealthMonitor()

    private static let logger = Logger(
        subsystem: AppBranding.loggerSubsystem,
        category: "PermissionHealth"
    )

    @Published private(set) var health: PermissionHealth = .needsAccessibility

    var onReadyTransition: (() -> Void)?

    var presentation: PermissionHealthPresentation {
        PermissionHealthPresentationPolicy.presentation(
            for: health,
            appName: runningAppName,
            appPath: Bundle.main.bundleURL.path
        )
    }

    private var runningAppName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppBranding.appName
    }

    private var activationObserver: NSObjectProtocol?
    private var retryTimer: Timer?
    private var probeGeneration: UInt64 = 0
    private var isProbeInFlight = false

    private init() {}

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PermissionHealthMonitor.shared.refresh()
            }
        }
        refresh()
    }

    func stop() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        retryTimer?.invalidate()
        retryTimer = nil
        probeGeneration &+= 1
        isProbeInFlight = false
    }

    func refresh() {
        if !AXIsProcessTrusted() {
            probeGeneration &+= 1
            isProbeInFlight = false
            update(
                PermissionHealthPolicy.evaluate(
                    accessibilityTrusted: false,
                    functionalProbe: .notRun
                )
            )
            scheduleRetryIfNeeded()
            return
        }

        guard !isProbeInFlight else { return }
        isProbeInFlight = true
        probeGeneration &+= 1
        let generation = probeGeneration

        if health != .ready {
            update(
                PermissionHealthPolicy.evaluate(
                    accessibilityTrusted: true,
                    functionalProbe: .notRun
                )
            )
        }

        guard let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier else {
            isProbeInFlight = false
            scheduleRetryIfNeeded()
            return
        }

        Task {
            let result = await Task.detached(priority: .utility) {
                AccessibilityFunctionalProbeRunner.run(applicationPID: finderPID)
            }.value
            guard generation == probeGeneration else { return }
            isProbeInFlight = false
            update(
                PermissionHealthPolicy.evaluate(
                    accessibilityTrusted: true,
                    functionalProbe: result
                )
            )
            scheduleRetryIfNeeded()
        }
    }

    func performPrimarySetupAction() {
        switch PermissionSetupPolicy.primaryAction(for: health) {
        case .requestAccessibility:
            requestAccessibilityAccess()
        case .openAccessibilitySettings:
            openAccessibilitySettings()
        case .revealRunningApp:
            revealRunningApp()
        case .none:
            refresh()
        }
    }

    func requestAccessibilityAccess() {
        guard !AXIsProcessTrusted() else {
            refresh()
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        scheduleRetryIfNeeded()
    }

    func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func update(_ newHealth: PermissionHealth) {
        let oldHealth = health
        guard oldHealth != newHealth else { return }
        health = newHealth
        Self.logger.notice(
            "Accessibility health changed from \(String(describing: oldHealth), privacy: .public) to \(String(describing: newHealth), privacy: .public), app=\(Bundle.main.bundleURL.path, privacy: .public)"
        )

        if PermissionHealthPolicy.requiresRecoveryWork(from: oldHealth, to: newHealth) {
            onReadyTransition?()
            NotificationCenter.default.post(name: .agentVisorAccessibilityRecovered, object: nil)
        }
    }

    private func scheduleRetryIfNeeded() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard health != .ready else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            Task { @MainActor in
                PermissionHealthMonitor.shared.refresh()
            }
        }
    }
}

private enum AccessibilityFunctionalProbeRunner {
    nonisolated static func run(applicationPID: pid_t) -> AccessibilityFunctionalProbe {
        let application = AXUIElementCreateApplication(applicationPID)
        var menuBar: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXMenuBarAttribute as CFString,
            &menuBar
        )
        return error == .success && menuBar != nil ? .passed : .failed
    }
}
