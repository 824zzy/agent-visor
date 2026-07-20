import AppKit
import ApplicationServices
import AgentVisorCore
import IOKit
import Mixpanel
import os.log
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "AppDelegate")
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.824zzy.AgentVisor",
        "com.824zzy.AgentVisor.Dev",
    ]

    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    /// Phase 0 of the window-mode rollout. While `WindowModeFlag.isEnabled()`
    /// is false this stays nil and only the notch panel is created. While
    /// true the main window is built alongside the notch so we can develop
    /// it incrementally without disturbing existing users.
    private var mainWindowController: MainWindowController?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver
    private let updaterDelegate: SparkleQuarantineFix

    func openSettings() {
        let controller = ensureMainWindowController()
        if MainWindowActivationPolicy.action(for: .settings) == .show {
            controller.showSettings()
        }
    }

    func openUpdateDetails(checkNow: Bool) {
        let controller = ensureMainWindowController()
        controller.showUpdates()
        if checkNow {
            UpdateManager.shared.checkForUpdates()
        }
    }

    func requestMainWindowActivation(_ reason: MainWindowActivationReason) {
        switch MainWindowActivationPolicy.action(for: reason) {
        case .show:
            if reason == .settings {
                ensureMainWindowController().showSettings()
            } else {
                ensureMainWindowController().showSessions()
            }
        case .toggle:
            ensureMainWindowController().toggleSessions()
        case .ignore:
            break
        }
    }

    func openSessionInMainWindow(_ sessionId: String) {
        ensureMainWindowController().showSession(sessionId)
    }

    /// Live `ClaudeSessionMonitor` owned by the pills-strip controller.
    /// Phase 4 reuses it to dispatch approve/deny from notification
    /// actions, since there's no `.shared` instance.
    var sessionMonitor: ClaudeSessionMonitor? {
        windowManager?.pillsStripController?.sessionMonitor
    }

    override init() {
        userDriver = NotchUserDriver()
        updaterDelegate = SparkleQuarantineFix()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: updaterDelegate
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            Self.logger.error("Failed to start Sparkle updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        // Install before any text view becomes visible so the first selection
        // already uses the Catppuccin override.
        SelectionColorOverride.install()

        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")

        // Defer analytics work off the main thread. This was previously
        // synchronous: `fetchAndRegisterClaudeVersion` walks every
        // directory in ~/.claude/projects (4k+ on heavy users) and
        // stats every JSONL inside, then `Mixpanel.flush` does a
        // synchronous network round-trip. Together they were eating
        // ~10s of boot before the window could render.
        DispatchQueue.global(qos: .utility).async {
            Self.fetchAndRegisterClaudeVersion()
            Mixpanel.mainInstance().flush()
        }

        HookInstaller.installIfNeeded()
        ImagePasteSender.cleanupStaleFiles()
        // Trigger the "Agent Visor wants to control X" TCC prompts now
        // (before the notch is open) so the system alert lands on top of
        // the desktop instead of behind the high-windowLevel notch panel.
        // Without this, the first AppleScript call happens when the user
        // types in chat — and the alert is unreachable, forcing a pkill.
        TCCPrewarm.start()
        // Tail Cursor's claude-code extension logs to mirror the
        // auto-generated session titles (the names users see on chat
        // tabs in Cursor) into agent-visor's pill labels. Cursor's
        // extension doesn't support /rename, so without this users
        // can't tell multiple sessions in the same workspace apart.
        CursorSessionTitleWatcher.shared.start()
        // Wire the Codex app-server bridge: routes the engine's approval
        // requests onto our approval bar and drives turn-phase from the
        // notification stream, so idle Codex threads are drivable
        // end-to-end from the composer (no switching back to Codex.app).
        // The app-server process itself is spawned lazily on first send.
        CodexAppServerApprovalBridge.shared.install()
        CodexUsageMonitor.shared.start()
#if DEBUG
        Task { @MainActor in
            await CodexConnectedRuntimeCoordinator.shared.resumePersistedIntent()
        }
#endif
        // Phase 3 (window-mode preview): flip to .regular so the new
        // window participates in Cmd-Tab and Dock just like Codex /
        // Cursor / Claude Desktop. The notch path stays .accessory
        // until Phase 5 retires the notch entirely. Anchored on the
        // same env flag as the rest of the rollout so users on the
        // shipping build are unaffected.
        // Window mode is now the default. Flip to .regular so the main
        // window participates in Cmd-Tab and Dock just like Codex /
        // Cursor / Claude Desktop. Info.plist has `LSUIElement = true`
        // so the shipping build classifies as a UI-element accessory;
        // setActivationPolicy(.regular) alone is not enough because
        // Launch Services has already cached that classification.
        // TransformProcessType re-registers us with the process server
        // as a foreground app, which flips Cmd-Tab visibility on.
        // setActivationPolicy stays afterwards as the source of truth
        // for AppKit's own activation behavior.
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
        NSApplication.shared.setActivationPolicy(.regular)

        PermissionHealthMonitor.shared.onReadyTransition = {
            HotkeyManager.shared.rearmAfterAccessibilityRecovery()
        }
        PermissionHealthMonitor.shared.start()

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        // Window mode is now the default workspace. The notch panel is
        // dead code in this build — only the menu-bar pills strip from
        // WindowManager survives. Approval banners + dock badge are
        // unconditional now.
        _ = ensureMainWindowController()
        requestMainWindowActivation(.appLaunch)
        ApprovalNotifier.shared.start()

        // Bridge legacy notch-panel "open" call sites (notch-shape tap,
        // overflow pill, etc.) to the main window. Without this the
        // pills-strip click-on-notch geometry handler would still
        // invoke `notchOpen` via `NotchViewModel.handleMouseDown` and
        // pop an empty panel container under the menu bar.
        NotchPanelRedirect.openMainWindow = { [weak self] in
            DispatchQueue.main.async { self?.requestMainWindowActivation(.notchClick) }
        }
        PillAccessibilityStatusItemController.shared.start()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        // AV_PROBE_SCALE_NOTIF / AV_PROBE_LOAD probes targeted the
        // legacy notch panel window and have been retired with it.

        // Phase 2: settings-driven trigger. The picker writes through to
        // AppSettings + HotkeyManager.applyTrigger directly, so we just
        // apply the persisted choice on launch. Phase 3 will add an
        // arbitrary chord recorder.
        HotkeyManager.shared.onTrigger = { [weak self] in
            // Hotkey toggles the main window. The notch chat panel is
            // gone — the menu-bar pills strip remains via WindowManager.
            self?.requestMainWindowActivation(.hotkey)
        }
        HotkeyManager.shared.applyTrigger(AppSettings.hotkeyTrigger)

        GlobalSessionShortcutManager.shared.onNavigate = { session in
            SessionNavigationRecencyStore.shared.record(session)
            PillFlashStore.shared.flash(session.stableId)
            SessionOpenRouter.smartOpen(session, modifierIntent: .standard)
        }
        GlobalSessionShortcutManager.shared.apply(AppSettings.sessionShortcutModifierFamily)

        if updater.canCheckForUpdates, updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater,
                  updater.canCheckForUpdates,
                  updater.automaticallyChecksForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    /// Dock-icon click / Cmd-Tab return when no main window is
    /// visible. Phase 3 of the window-mode rollout — when the main
    /// window has been hidden via close-hides, the user expects
    /// clicking the dock icon to bring it back. AppKit's default
    /// behavior under .regular is to do nothing (since we have no
    /// `main` window), so we override.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            requestMainWindowActivation(.appReopen)
        }
        return true
    }

    private func ensureMainWindowController() -> MainWindowController {
        if let controller = mainWindowController {
            return controller
        }
        let controller = MainWindowController()
        mainWindowController = controller
        return controller
    }

    func applicationWillTerminate(_ notification: Notification) {
#if DEBUG
        Task { @MainActor in
            await CodexConnectedRuntimeCoordinator.shared.shutdownForAppTermination()
        }
#endif
        // Kill any visor-spawned claude subprocesses so headless
        // children don't outlive the app. Synchronous SIGTERM via
        // the actor — short-lived call, safe to block on shutdown.
        Task { await SpawnedSessionManager.shared.terminateAll() }
        Mixpanel.mainInstance().flush()
        updateCheckTimer?.invalidate()
        PermissionHealthMonitor.shared.stop()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    /// Walks ~/.claude/projects/<project>/<sessionId>.jsonl to find
    /// the most recently modified JSONL, reads its first 8KB, and
    /// registers the `claude_code_version` field as a Mixpanel super
    /// property. EXPENSIVE: thousands of FS reads on heavy users.
    /// Static so it can run on a background queue without capturing
    /// the AppDelegate.
    private static func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
            return
        }
    }

    private func ensureSingleInstance() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            Self.supportedBundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                Self.logger.notice(
                    "Another Agent Visor variant is already running: \(existingApp.bundleIdentifier ?? "unknown", privacy: .public)"
                )
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
