import Foundation

public let nativeHelperProtocolVersion = 1

/// Hard limits shared with the Electron protocol. Terminal text is measured
/// in UTF-8 bytes because the native helper ultimately writes the payload to a
/// PTY; frame bytes are the length-prefixed JSON payload, excluding its
/// four-byte prefix.
public enum NativeHelperWireLimits {
    public static let maxTerminalTextBytes = 65_536
    public static let maxFramePayloadBytes = 1_048_576
}

// Keep the legacy names source-compatible for the helper executable while
// making the shared limits above the single source of truth.
public let nativeHelperMaximumTerminalTextBytes = NativeHelperWireLimits.maxTerminalTextBytes
public let nativeHelperMaximumPayloadBytes = NativeHelperWireLimits.maxFramePayloadBytes

public enum NativeHelperTimestamp {
    public static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? internet.date(from: value)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

public enum NativeHelperWireError: Error, Equatable {
    case invalidRequest
    case frameTooLarge
}

public enum NativeHelperPillPhase: String, Codable, Equatable {
    case needsYou = "needs_you"
    case ready
    case working
    case history
}

/// Lifecycle meaning resolved by the daemon before a pill crosses the wire.
/// This is separate from the phase/tier used for native placement.
public enum NativeHelperLifecycleStatus: String, Codable, Equatable {
    case needsYou = "needs_you"
    case ready
    case working
    case closed
    case unavailable
    case historical
}

public enum NativeHelperSessionAttentionTier: String, Codable, Equatable {
    case needsYou = "needs_you"
    case ready
    case working
    case acknowledgedReady = "acknowledged_ready"
    case history
}

public struct NativeHelperSessionInspectorRow: Codable, Equatable, Sendable {
    public let label: String
    public let value: String
}

public struct NativeHelperSessionInspectorContext: Codable, Equatable, Sendable {
    public let usedLabel: String
    public let windowLabel: String
    public let percentage: Int
}

public struct NativeHelperSessionInspector: Codable, Equatable, Sendable {
    public let status: String
    public let runtimeItems: [String]
    public let detailRows: [NativeHelperSessionInspectorRow]
    public let projectPath: String
    public let activityAt: String
    public let context: NativeHelperSessionInspectorContext?
}

public struct NativeHelperPill: Codable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let source: String?
    public let project: String?
    public let owner: String?
    public let inspector: NativeHelperSessionInspector?
    public let phase: NativeHelperPillPhase
    public let lifecycleStatus: NativeHelperLifecycleStatus?
    public let attentionTier: NativeHelperSessionAttentionTier?
    public let completionUnseen: Bool?
    /// Whether this needs-you pill represents a newly observed failure.
    /// Only `true` enables the native dismiss action; omitted and `false`
    /// preserve the normal pill behavior.
    public let failureAlert: Bool?
    /// Whether this navigator row should contribute to the default +N
    /// overflow count. Omitted values preserve the legacy wire behavior.
    public let defaultOverflowEligible: Bool?
    public let priority: Int
    public let accessibilityLabel: String

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        source: String? = nil,
        project: String? = nil,
        owner: String? = nil,
        inspector: NativeHelperSessionInspector? = nil,
        phase: NativeHelperPillPhase,
        lifecycleStatus: NativeHelperLifecycleStatus? = nil,
        attentionTier: NativeHelperSessionAttentionTier? = nil,
        completionUnseen: Bool? = nil,
        failureAlert: Bool? = nil,
        defaultOverflowEligible: Bool? = nil,
        priority: Int,
        accessibilityLabel: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.project = project
        self.owner = owner
        self.inspector = inspector
        self.phase = phase
        self.lifecycleStatus = lifecycleStatus
        self.attentionTier = attentionTier
        self.completionUnseen = completionUnseen
        self.failureAlert = failureAlert
        self.defaultOverflowEligible = defaultOverflowEligible
        self.priority = priority
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum NativeHelperUsageTone: String, Codable, Equatable {
    case normal
    case warning
    case critical
}

public struct NativeHelperUsageWindow: Codable, Equatable {
    public let title: String
    public let remainingPercent: Int
    public let tone: NativeHelperUsageTone?
    public let resetsAt: String?

    public init(
        title: String,
        remainingPercent: Int,
        tone: NativeHelperUsageTone? = nil,
        resetsAt: String? = nil
    ) {
        self.title = title
        self.remainingPercent = remainingPercent
        self.tone = tone
        self.resetsAt = resetsAt
    }
}

public struct NativeHelperUsageGlance: Codable, Equatable {
    public let id: String
    public let heading: String?
    public let width: Double?
    public let label: String
    public let detail: String
    public let summary: String?
    public let usageURL: String?
    public let tone: NativeHelperUsageTone
    public let priority: Int
    public let accessibilityLabel: String
    public let observedAt: String?
    public let windows: [NativeHelperUsageWindow]?
    public let resetCreditsAvailable: Int?
    public let stale: Bool?

    public init(
        id: String,
        heading: String? = nil,
        width: Double? = nil,
        label: String,
        detail: String,
        summary: String? = nil,
        usageURL: String? = nil,
        tone: NativeHelperUsageTone,
        priority: Int,
        accessibilityLabel: String,
        observedAt: String? = nil,
        windows: [NativeHelperUsageWindow]? = nil,
        resetCreditsAvailable: Int? = nil,
        stale: Bool? = nil
    ) {
        self.id = id
        self.heading = heading
        self.width = width
        self.label = label
        self.detail = detail
        self.summary = summary
        self.usageURL = usageURL
        self.tone = tone
        self.priority = priority
        self.accessibilityLabel = accessibilityLabel
        self.observedAt = observedAt
        self.windows = windows
        self.resetCreditsAvailable = resetCreditsAvailable
        self.stale = stale
    }
}

public enum NativeHelperTerminalApplication: String, Codable, Equatable {
    case ghostty = "Ghostty"
    case iTerm2 = "iTerm2"
    case terminal = "Terminal"
}

public struct NativeHelperTerminalTarget: Codable, Equatable {
    public let application: NativeHelperTerminalApplication
    /// Agent process identity. TTY names can be reused after a process exits.
    public let pid: Int32?
    /// Helper-derived process-instance identity. PID reuse must fail closed.
    /// ponytail: this token must come from the live process start identity;
    /// do not synthesize it from PID/TTY when extending discovery.
    public let processStartToken: String?
    public let tty: String
    public let cwd: String

    public init(
        application: NativeHelperTerminalApplication,
        pid: Int32? = nil,
        processStartToken: String? = nil,
        tty: String,
        cwd: String
    ) {
        self.application = application
        self.pid = pid
        self.processStartToken = processStartToken
        self.tty = tty
        self.cwd = cwd
    }
}

/// A presentation surface, independent of a Claude background worker's PTY.
public enum NativeHelperGhosttyViewMode: String, Codable { case conversation, overview }

public struct NativeHelperGhosttyTerminalView: Codable, Equatable {
    public let applicationPID: Int32
    public let processStartToken: String
    public let terminalId: String
    public let title: String
    public let cwd: String
    public let titleUpdatesEnabled: Bool?
    public let viewMode: NativeHelperGhosttyViewMode?

    public init(applicationPID: Int32, processStartToken: String, terminalId: String, title: String, cwd: String,
                titleUpdatesEnabled: Bool? = nil, viewMode: NativeHelperGhosttyViewMode? = nil) {
        self.applicationPID = applicationPID
        self.processStartToken = processStartToken
        self.terminalId = terminalId
        self.title = title
        self.cwd = cwd
        self.titleUpdatesEnabled = titleUpdatesEnabled
        self.viewMode = viewMode
    }

    public var isValid: Bool {
        titleUpdatesEnabled != false && applicationPID > 0 && !processStartToken.isEmpty && processStartToken.utf16.count <= 256
            && !terminalId.isEmpty && terminalId.utf16.count <= 128
            && !title.isEmpty && title.utf16.count <= 512 && cwd.hasPrefix("/") && cwd.utf16.count <= 4_096
            && ![terminalId, title, cwd, processStartToken].contains(where: { $0.contains("\0") })
    }
}

public struct NativeHelperProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let processStartToken: String
    public init(pid: Int32, processStartToken: String) { self.pid = pid; self.processStartToken = processStartToken }
}

/// A process-instance-bound Ghostty surface identified by a short-lived nonce
/// marker. Unlike the legacy title view, this identity is sufficient for an
/// exact native focus operation and carries no terminal content or input data.
public struct NativeHelperGhosttyBinding: Codable, Equatable {
    public let applicationPID: Int32
    public let processStartToken: String
    public let windowId: String
    public let tabId: String
    public let terminalId: String
    public let nonce: String

    public init(
        applicationPID: Int32,
        processStartToken: String,
        windowId: String,
        tabId: String,
        terminalId: String,
        nonce: String
    ) {
        self.applicationPID = applicationPID
        self.processStartToken = processStartToken
        self.windowId = windowId
        self.tabId = tabId
        self.terminalId = terminalId
        self.nonce = nonce
    }

    public var isValid: Bool {
        applicationPID > 0
            && validIdentity(processStartToken, maximum: 128)
            && validIdentity(windowId, maximum: 128)
            && validIdentity(tabId, maximum: 128)
            && validIdentity(terminalId, maximum: 128)
            && nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
    }

    private func validIdentity(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf16.count <= maximum && !value.contains("\0")
    }
}

public struct NativeHelperFocusTarget: Codable, Equatable {
    public let pid: Int32
    public let bundleIdentifier: String
    public let windowId: UInt32?

    public init(pid: Int32, bundleIdentifier: String, windowId: UInt32? = nil) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowId = windowId
    }
}

public struct NativeHelperCodexThreadTarget: Codable, Equatable {
    public let pid: Int32
    public let home: String
    public let threadId: String

    public init(pid: Int32, home: String, threadId: String) {
        self.pid = pid
        self.home = home
        self.threadId = threadId
    }

    public var isValid: Bool {
        pid > 0 && home.hasPrefix("/") && home.utf8.count <= 1_024
            && UUID(uuidString: threadId) != nil
    }
}

/// A Claude Code background job to attach to in a new terminal window.
public struct NativeHelperClaudeAttachTarget: Codable, Equatable {
    public let cwd: String
    public let executable: String
    public let jobId: String

    public init(cwd: String, executable: String, jobId: String) {
        self.cwd = cwd
        self.executable = executable
        self.jobId = jobId
    }

    public var isValid: Bool {
        cwd.hasPrefix("/") && cwd.utf8.count <= 1_024
            && executable.hasPrefix("/") && executable.utf8.count <= 1_024
            && jobId.range(of: "^[0-9a-fA-F]{8}$", options: .regularExpression) != nil
    }
}

/// A typed, exact-ID Claude launch in a new Ghostty surface. The native side
/// owns command construction; arbitrary shell text never crosses this wire.
public struct NativeHelperGhosttyResumeTarget: Codable, Equatable {
    public let attemptId: String
    public let provider: String
    public let sessionId: String
    public let cwd: String
    public let executable: String
    public let configRoot: String?
    public let settingsFile: String?
    public let settingSources: [String]?
    public let profileRef: String?
    public let profileState: String
    public let nonce: String

    public init(
        attemptId: String,
        provider: String = "claude_code",
        sessionId: String,
        cwd: String,
        executable: String,
        configRoot: String? = nil,
        settingsFile: String? = nil,
        settingSources: [String]? = nil,
        profileRef: String? = nil,
        profileState: String,
        nonce: String
    ) {
        self.attemptId = attemptId
        self.provider = provider
        self.sessionId = sessionId
        self.cwd = cwd
        self.executable = executable
        self.configRoot = configRoot
        self.settingsFile = settingsFile
        self.settingSources = settingSources
        self.profileRef = profileRef
        self.profileState = profileState
        self.nonce = nonce
    }

    public var isValid: Bool {
        (provider == "claude_code" || provider == "codex_cli")
            && validOpaque(attemptId, maximum: 128)
            && sessionId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: [.regularExpression, .caseInsensitive]) != nil
            && absolutePath(cwd, maximum: 4_096)
            && absolutePath(executable, maximum: 4_096)
            && (configRoot.map { absolutePath($0, maximum: 4_096) } ?? true)
            && (settingsFile.map { absolutePath($0, maximum: 4_096) } ?? true)
            && (provider != "codex_cli" || (configRoot != nil && settingsFile == nil && settingSources == nil))
            && (settingSources?.count ?? 0) <= 3
            && (settingSources ?? []).allSatisfy { ["user", "project", "local"].contains($0) }
            && (profileRef.map { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil } ?? true)
            && (profileState == "present" || profileState == "verified_absent")
            && nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
    }
}

public struct NativeHelperGhosttyResumeDispatch: Codable, Equatable {
    public let attemptId: String
    public let provider: String
    public let sessionId: String
    public let applicationPID: Int32
    public let processStartToken: String
    public let windowId: String
    public let tabId: String
    public let terminalId: String
    public let nonce: String
    public let dispatchedAt: String

    public init(
        attemptId: String,
        provider: String = "claude_code",
        sessionId: String,
        applicationPID: Int32,
        processStartToken: String,
        windowId: String,
        tabId: String,
        terminalId: String,
        nonce: String,
        dispatchedAt: String
    ) {
        self.attemptId = attemptId
        self.provider = provider
        self.sessionId = sessionId
        self.applicationPID = applicationPID
        self.processStartToken = processStartToken
        self.windowId = windowId
        self.tabId = tabId
        self.terminalId = terminalId
        self.nonce = nonce
        self.dispatchedAt = dispatchedAt
    }

    public var isValid: Bool {
        (provider == "claude_code" || provider == "codex_cli")
            && validOpaque(attemptId, maximum: 128)
            && sessionId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: [.regularExpression, .caseInsensitive]) != nil
            && applicationPID > 0
            && validOpaque(processStartToken, maximum: 256)
            && validOpaque(windowId, maximum: 128)
            && validOpaque(tabId, maximum: 128)
            && validOpaque(terminalId, maximum: 128)
            && nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
            && NativeHelperTimestamp.parse(dispatchedAt) != nil
    }
}

public struct NativeHelperProcessProvenanceTarget: Codable, Equatable {
    public let pid: Int32
    public let provider: NativeProcessProvenanceProvider
    public let processStartToken: String
    public let homeDirectory: String

    public init(
        pid: Int32,
        provider: NativeProcessProvenanceProvider,
        processStartToken: String,
        homeDirectory: String
    ) {
        self.pid = pid
        self.provider = provider
        self.processStartToken = processStartToken
        self.homeDirectory = homeDirectory
    }

    public var isValid: Bool {
        pid > 0
            && validOpaque(processStartToken, maximum: 256)
            && absolutePath(homeDirectory, maximum: 4_096)
    }
}

private func absolutePath(_ value: String, maximum: Int) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= maximum && !value.contains("\0")
}

private func validOpaque(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
}

public enum NativeHelperHotkeyTrigger: String, Codable, Equatable {
    case off
    case cmd
    case ctrl
    case option
    case shift
    case custom
}

public struct NativeHelperPillScreen: Codable, Equatable {
    public enum Mode: String, Codable, Equatable {
        case automatic
        case specific
    }

    public let mode: Mode
    public let displayId: UInt32?
    public let name: String?
    /// Stable per-monitor identity; macOS can reuse a display ID across docks.
    public let displayUuid: String?

    public static let automatic = NativeHelperPillScreen(
        mode: .automatic,
        displayId: nil,
        name: nil
    )

    public static func specific(
        displayId: UInt32,
        name: String,
        displayUuid: String? = nil
    ) -> Self {
        NativeHelperPillScreen(
            mode: .specific,
            displayId: displayId,
            name: name,
            displayUuid: displayUuid
        )
    }

    public init(mode: Mode, displayId: UInt32?, name: String?, displayUuid: String? = nil) {
        self.mode = mode
        self.displayId = displayId
        self.name = name
        self.displayUuid = displayUuid
    }
}

public enum NativeHelperNotificationPermission: String, Codable, Equatable {
    case notDetermined = "not_determined"
    case denied
    case authorized
}

public enum NativeHelperNotificationSound: String, Codable, Equatable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"
}

public struct NativeHelperNotification: Codable, Equatable {
    public let id: String
    public let sessionId: String
    public let title: String
    public let subtitle: String?
    public let body: String
    public let toolUseId: String?
    public let sound: NativeHelperNotificationSound
}

public struct NativeHelperPiRestorationCandidate: Codable, Equatable {
    public let sessionId: String
    public let sessionFile: String
    public let cwd: String
    public let sessionName: String?
    public let pid: Int32
    public let tty: String
}

public struct NativeHelperPiRestorationUpdate: Codable, Equatable {
    public let candidates: [NativeHelperPiRestorationCandidate]
    public let liveSessionIds: [String]
    public let removeCandidateSessionIds: [String]
    public let cleanTermination: Bool
}

public enum NativeHelperRequest: Equatable {
    case screenTopology(id: String)
    case accessibilityStatus(id: String)
    case notificationStatus(id: String)
    case requestNotifications(id: String)
    case reconcileNotifications(
        id: String,
        notifications: [NativeHelperNotification],
        presentNew: Bool
    )
    case reconcilePiRestoration(id: String, update: NativeHelperPiRestorationUpdate)
    case requestAccessibility(id: String)
    case openAccessibilitySettings(id: String)
    case presentPills(
        id: String,
        pills: [NativeHelperPill],
        navigatorPills: [NativeHelperPill],
        usageGlances: [NativeHelperUsageGlance],
        shortcutModifierFamily: SessionShortcutModifierFamily?,
        pillScreen: NativeHelperPillScreen?,
        fullScreenPolicy: FullScreenPillPolicy?,
        hotkeyTrigger: NativeHelperHotkeyTrigger?,
        customHotkeyCombo: KeyCombo?
    )
    case focus(id: String, target: NativeHelperFocusTarget)
    case openCodexThread(id: String, target: NativeHelperCodexThreadTarget)
    case openClaudeAttach(id: String, target: NativeHelperClaudeAttachTarget)
    case openGhosttyResume(id: String, target: NativeHelperGhosttyResumeTarget)
    case readProcessProvenance(id: String, target: NativeHelperProcessProvenanceTarget)
    case focusTerminal(id: String, target: NativeHelperTerminalTarget, conversationOnly: Bool? = nil)
    case prepareTerminal(id: String, target: NativeHelperTerminalTarget, conversationOnly: Bool = true)
    case ghosttyTerminalViews(id: String, conversationTitles: [String] = [])
    case focusGhosttyTerminal(id: String, target: NativeHelperGhosttyTerminalView)
    case ghosttyBindingStatus(id: String)
    case resolveGhosttyBinding(id: String, nonce: String)
    case focusGhosttyBinding(id: String, target: NativeHelperGhosttyBinding)
    case prepareGhosttyBinding(id: String, target: NativeHelperGhosttyBinding, processes: [NativeHelperProcessIdentity])
    case sendTerminal(id: String, target: NativeHelperTerminalTarget, text: String, submit: Bool)
    case cancelTerminal(id: String, target: NativeHelperTerminalTarget)
    case cyclePermissionMode(id: String, target: NativeHelperTerminalTarget)

    public var id: String {
        switch self {
        case .ghosttyTerminalViews(let id, _), .focusGhosttyTerminal(let id, _),
             .ghosttyBindingStatus(let id), .resolveGhosttyBinding(let id, _),
             .focusGhosttyBinding(let id, _), .prepareTerminal(let id, _, _), .prepareGhosttyBinding(let id, _, _),
             .screenTopology(let id), .accessibilityStatus(let id),
             .notificationStatus(let id), .requestNotifications(let id),
             .reconcileNotifications(let id, _, _),
             .reconcilePiRestoration(let id, _), .requestAccessibility(let id),
             .openAccessibilitySettings(let id),
             .presentPills(let id, _, _, _, _, _, _, _, _), .focus(let id, _),
             .openCodexThread(let id, _), .openClaudeAttach(let id, _),
             .openGhosttyResume(let id, _),
             .readProcessProvenance(let id, _),
             .focusTerminal(let id, _, _), .sendTerminal(let id, _, _, _),
             .cancelTerminal(let id, _), .cyclePermissionMode(let id, _):
            id
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= nativeHelperMaximumPayloadBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            throw NativeHelperWireError.invalidRequest
        }

        let requiredKeys: Set<String> = [
            "present_pills", "reconcile_notifications", "reconcile_pi_restoration",
                "focus", "open_codex_thread", "open_claude_attach", "open_ghostty_resume", "read_process_provenance", "focus_terminal", "send_terminal",
                "cancel_terminal", "cycle_permission_mode", "focus_ghostty_terminal",
                "resolve_ghostty_binding", "focus_ghostty_binding", "prepare_terminal", "prepare_ghostty_binding",
        ].contains(method) || (method == "ghostty_terminal_views" && object["params"] != nil)
            ? ["version", "id", "method", "params"]
            : ["version", "id", "method"]
        guard Set(object.keys) == requiredKeys,
              hasStrictNestedFields(method: method, object: object) else {
            throw NativeHelperWireError.invalidRequest
        }

        let wire = try JSONDecoder().decode(WireRequest.self, from: data)
        guard wire.version == nativeHelperProtocolVersion,
              !wire.id.isEmpty, wire.id.count <= 128 else {
            throw NativeHelperWireError.invalidRequest
        }

        switch method {
        case "ghostty_terminal_views":
            if let params = wire.params {
                guard Set(params.keys) == ["conversationTitles"], let titles = params.conversationTitles,
                      titles.count <= 64, titles.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 512 && !$0.contains("\0") }) else {
                    throw NativeHelperWireError.invalidRequest
                }
            }
            return .ghosttyTerminalViews(id: wire.id, conversationTitles: wire.params?.conversationTitles ?? [])
        case "focus_ghostty_terminal":
            guard let target = wire.params?.ghosttyTerminalTarget, target.isValid else {
                throw NativeHelperWireError.invalidRequest
            }
            return .focusGhosttyTerminal(id: wire.id, target: target)
        case "ghostty_binding_status":
            return .ghosttyBindingStatus(id: wire.id)
        case "resolve_ghostty_binding":
            guard let params = wire.params,
                  Set(params.keys) == ["nonce"],
                  let nonce = params.nonce,
                  nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
                throw NativeHelperWireError.invalidRequest
            }
            return .resolveGhosttyBinding(id: wire.id, nonce: nonce)
        case "focus_ghostty_binding":
            guard let target = wire.params?.ghosttyBindingTarget, target.isValid else {
                throw NativeHelperWireError.invalidRequest
            }
            return .focusGhosttyBinding(id: wire.id, target: target)
        case "prepare_ghostty_binding":
            guard let params = wire.params, let target = params.ghosttyBindingTarget, target.isValid,
                  let processes = params.processes, !processes.isEmpty, processes.count <= 4,
                  processes.allSatisfy({ $0.pid > 0 && !$0.processStartToken.isEmpty
                    && $0.processStartToken.utf16.count <= 256 && !$0.processStartToken.contains("\0") }) else {
                throw NativeHelperWireError.invalidRequest
            }
            return .prepareGhosttyBinding(id: wire.id, target: target, processes: processes)
        case "screen_topology":
            return .screenTopology(id: wire.id)
        case "accessibility_status":
            return .accessibilityStatus(id: wire.id)
        case "request_accessibility":
            return .requestAccessibility(id: wire.id)
        case "notification_status":
            return .notificationStatus(id: wire.id)
        case "request_notifications":
            return .requestNotifications(id: wire.id)
        case "reconcile_notifications":
            guard let params = wire.params,
                  Set(params.keys) == ["notifications", "presentNew"],
                  let notifications = params.notifications,
                  notifications.count <= 128,
                  notifications.allSatisfy(\.isValid),
                  let presentNew = params.presentNew else {
                throw NativeHelperWireError.invalidRequest
            }
            return .reconcileNotifications(
                id: wire.id,
                notifications: notifications,
                presentNew: presentNew
            )
        case "reconcile_pi_restoration":
            guard let params = wire.params,
                  Set(params.keys) == [
                    "candidates", "liveSessionIds", "removeCandidateSessionIds",
                    "cleanTermination",
                  ],
                  let candidates = params.piRestorationCandidates,
                  candidates.count <= 64,
                  candidates.allSatisfy(\.isValid),
                  let liveSessionIds = params.liveSessionIds,
                  let removeCandidateSessionIds = params.removeCandidateSessionIds,
                  liveSessionIds.count <= 64,
                  removeCandidateSessionIds.count <= 64,
                  (liveSessionIds + removeCandidateSessionIds)
                    .allSatisfy(\.isValidRestorationSessionID),
                  let cleanTermination = params.cleanTermination else {
                throw NativeHelperWireError.invalidRequest
            }
            return .reconcilePiRestoration(
                id: wire.id,
                update: NativeHelperPiRestorationUpdate(
                    candidates: candidates,
                    liveSessionIds: liveSessionIds,
                    removeCandidateSessionIds: removeCandidateSessionIds,
                    cleanTermination: cleanTermination
                )
            )
        case "open_accessibility_settings":
            return .openAccessibilitySettings(id: wire.id)
        case "present_pills":
            guard let params = wire.params,
                  Set(params.keys).contains("pills"),
                  Set(params.keys).isSubset(of: [
                    "pills", "navigatorPills", "usageGlances", "shortcutModifierFamily",
                    "pillScreen", "fullScreenPolicy", "hotkeyTrigger", "customHotkeyCombo",
                  ]),
                  let pills = params.pills, pills.count <= 64,
                  (params.navigatorPills?.count ?? 0) <= 512,
                  (params.usageGlances?.count ?? 0) <= 8,
                  pills.allSatisfy({ $0.isValid }),
                  (params.navigatorPills ?? []).allSatisfy({ $0.isValid }),
                  (params.usageGlances ?? []).allSatisfy({ $0.isValid }) else {
                throw NativeHelperWireError.invalidRequest
            }
            let shortcutFamily = params.shortcutModifierFamily.flatMap(
                SessionShortcutModifierFamily.init(rawValue:)
            )
            let hotkeyTrigger = params.hotkeyTrigger.flatMap(
                NativeHelperHotkeyTrigger.init(rawValue:)
            )
            let fullScreenPolicy = params.fullScreenPolicy.flatMap(
                FullScreenPillPolicy.init(rawValue:)
            )
            let customCombo = params.customHotkeyCombo.flatMap(KeyCombo.fromSerialized)
            guard params.shortcutModifierFamily == nil || shortcutFamily != nil,
                  params.pillScreen?.isValid ?? true,
                  params.fullScreenPolicy == nil || fullScreenPolicy != nil,
                  params.hotkeyTrigger == nil || hotkeyTrigger != nil,
                  params.customHotkeyCombo == nil || (
                    (params.customHotkeyCombo?.count ?? 0) <= 8
                    && customCombo.map(KeyComboValidator.isValid) == true
                    && customCombo.map { $0.modifiers.rawValue & ~15 == 0 } == true
                  ) else {
                throw NativeHelperWireError.invalidRequest
            }
            return .presentPills(
                id: wire.id,
                pills: pills,
                navigatorPills: params.navigatorPills ?? pills,
                usageGlances: params.usageGlances ?? [],
                shortcutModifierFamily: shortcutFamily,
                pillScreen: params.pillScreen,
                fullScreenPolicy: fullScreenPolicy,
                hotkeyTrigger: hotkeyTrigger,
                customHotkeyCombo: customCombo
            )
        case "focus":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.target,
                  target.pid > 0,
                  !target.bundleIdentifier.isEmpty,
                  target.bundleIdentifier.count <= 255 else {
                throw NativeHelperWireError.invalidRequest
            }
            return .focus(id: wire.id, target: target)
        case "open_codex_thread":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.codexThreadTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .openCodexThread(id: wire.id, target: target)
        case "open_claude_attach":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.claudeAttachTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .openClaudeAttach(id: wire.id, target: target)
        case "open_ghostty_resume":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.ghosttyResumeTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .openGhosttyResume(id: wire.id, target: target)
        case "read_process_provenance":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.processProvenanceTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .readProcessProvenance(id: wire.id, target: target)
        case "focus_terminal":
            guard let params = wire.params,
                  Set(params.keys).isSubset(of: ["target", "conversationOnly"]),
                  let target = params.terminalTarget,
                  target.isValid, params.conversationOnly == nil || target.application == .ghostty else {
                throw NativeHelperWireError.invalidRequest
            }
            return .focusTerminal(id: wire.id, target: target, conversationOnly: params.conversationOnly)
        case "prepare_terminal":
            guard let params = wire.params, Set(params.keys).isSubset(of: ["target", "conversationOnly"]),
                  let target = params.terminalTarget, target.isValid,
                  target.application == .ghostty else { throw NativeHelperWireError.invalidRequest }
            return .prepareTerminal(id: wire.id, target: target, conversationOnly: params.conversationOnly ?? true)
        case "send_terminal":
            guard let params = wire.params,
                  Set(params.keys) == ["target", "text", "submit"],
                  let target = params.terminalTarget,
                  let text = params.text,
                  text.utf8.count <= nativeHelperMaximumTerminalTextBytes,
                  let submit = params.submit,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .sendTerminal(id: wire.id, target: target, text: text, submit: submit)
        case "cancel_terminal":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.terminalTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .cancelTerminal(id: wire.id, target: target)
        case "cycle_permission_mode":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.terminalTarget,
                  target.isValid else { throw NativeHelperWireError.invalidRequest }
            return .cyclePermissionMode(id: wire.id, target: target)
        default:
            throw NativeHelperWireError.invalidRequest
        }
    }
}

public struct NativeHelperRectangle: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct NativeHelperScreen: Codable, Equatable {
    public let displayId: UInt32
    public let displayUuid: String?
    public let name: String
    public let isBuiltIn: Bool
    public let frame: NativeHelperRectangle
    public let visibleFrame: NativeHelperRectangle
    public let scale: Double
    public let isMain: Bool

    public init(
        displayId: UInt32,
        displayUuid: String? = nil,
        name: String,
        isBuiltIn: Bool,
        frame: NativeHelperRectangle,
        visibleFrame: NativeHelperRectangle,
        scale: Double,
        isMain: Bool
    ) {
        self.displayId = displayId
        self.displayUuid = displayUuid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
    }
}

public enum NativeHelperErrorCode: String, Codable {
    case invalidRequest = "invalid_request"
    case unsupported
    case failed
}

public enum NativeHelperResponse {
    case ghosttyTerminalViews(id: String, views: [NativeHelperGhosttyTerminalView])
    case ghosttyResumeDispatched(id: String, dispatch: NativeHelperGhosttyResumeDispatch)
    case processProvenance(id: String, result: NativeProcessProvenanceResult)
    case ghosttyBindingStatus(id: String, available: Bool)
    case ghosttyBinding(id: String, binding: NativeHelperGhosttyBinding)
    case screenTopology(id: String, screens: [NativeHelperScreen])
    case accessibilityStatus(id: String, trusted: Bool)
    case notificationStatus(id: String, status: NativeHelperNotificationPermission)
    case accepted(id: String)
    case error(id: String, code: NativeHelperErrorCode, message: String, reason: String? = nil, systemCode: Int? = nil)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .ghosttyTerminalViews(let id, let views):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion, id: id, ok: true,
                result: .ghosttyTerminalViews(views)
            ))
        case .ghosttyResumeDispatched(let id, let dispatch):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .ghosttyResumeDispatched(dispatch)
            ))
        case .processProvenance(let id, let result):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .processProvenance(result)
            ))
        case .ghosttyBindingStatus(let id, let available):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .ghosttyBindingStatus(available)
            ))
        case .ghosttyBinding(let id, let binding):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .ghosttyBinding(binding)
            ))
        case .screenTopology(let id, let screens):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .screenTopology(screens)
            ))
        case .accessibilityStatus(let id, let trusted):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .accessibilityStatus(trusted)
            ))
        case .notificationStatus(let id, let status):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .notificationStatus(status)
            ))
        case .accepted(let id):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .accepted
            ))
        case .error(let id, let code, let message, let reason, let systemCode):
            return try encoder.encode(ErrorEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: false,
                error: .init(code: code, message: String(message.prefix(512)), reason: reason, systemCode: systemCode)
            ))
        }
    }
}

public enum NativeHelperPillActivationIntent: String, Encodable, Equatable {
    case standard
    case chat
    case dismiss
}

public enum NativeHelperNotificationAction: String, Encodable, Equatable {
    case activate
    case approve
    case deny
}

public enum NativeHelperEvent {
    case activatePill(
        sessionId: String,
        intent: NativeHelperPillActivationIntent = .standard,
        activatedAt: Double = Date().timeIntervalSince1970 * 1_000
    )
    case openSessions
    case toggleSessions
    case openSettings
    case refreshUsage
    case notificationPermission(NativeHelperNotificationPermission)
    case notificationAction(
        sessionId: String,
        toolUseId: String?,
        action: NativeHelperNotificationAction
    )

    public func encoded() throws -> Data {
        let envelope: EventEnvelope
        switch self {
        case .activatePill(let sessionId, let intent, let activatedAt):
            envelope = EventEnvelope(
                event: "activate_pill",
                sessionId: sessionId,
                intent: intent == .standard ? nil : intent,
                activatedAt: activatedAt
            )
        case .openSessions:
            envelope = EventEnvelope(event: "open_sessions", sessionId: nil, intent: nil)
        case .toggleSessions:
            envelope = EventEnvelope(event: "toggle_sessions", sessionId: nil, intent: nil)
        case .openSettings:
            envelope = EventEnvelope(event: "open_settings", sessionId: nil, intent: nil)
        case .refreshUsage:
            envelope = EventEnvelope(event: "refresh_usage")
        case .notificationPermission(let status):
            envelope = EventEnvelope(event: "notification_permission", status: status)
        case .notificationAction(let sessionId, let toolUseId, let action):
            envelope = EventEnvelope(
                event: "notification_action",
                sessionId: sessionId,
                toolUseId: toolUseId,
                action: action
            )
        }
        return try JSONEncoder().encode(envelope)
    }
}

private struct EventEnvelope: Encodable {
    let version = nativeHelperProtocolVersion
    let type = "event"
    let event: String
    let sessionId: String?
    let intent: NativeHelperPillActivationIntent?
    let status: NativeHelperNotificationPermission?
    let toolUseId: String?
    let action: NativeHelperNotificationAction?
    let activatedAt: Double?

    init(
        event: String,
        sessionId: String? = nil,
        intent: NativeHelperPillActivationIntent? = nil,
        status: NativeHelperNotificationPermission? = nil,
        toolUseId: String? = nil,
        action: NativeHelperNotificationAction? = nil,
        activatedAt: Double? = nil
    ) {
        self.event = event
        self.sessionId = sessionId
        self.intent = intent
        self.status = status
        self.toolUseId = toolUseId
        self.action = action
        self.activatedAt = activatedAt
    }
}

public enum NativeHelperFrameCodec {
    public static func frame(
        _ payload: Data,
        maxPayloadBytes: Int = nativeHelperMaximumPayloadBytes
    ) throws -> Data {
        guard payload.count <= maxPayloadBytes, payload.count <= Int(UInt32.max) else {
            throw NativeHelperWireError.frameTooLarge
        }
        let size = UInt32(payload.count)
        var framed = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff),
        ])
        framed.append(payload)
        return framed
    }
}

public struct NativeHelperFrameDecoder {
    private var buffer = Data()
    private let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = nativeHelperMaximumPayloadBytes) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public mutating func append<D: DataProtocol>(_ bytes: D) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var payloads: [Data] = []

        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size <= maxPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw NativeHelperWireError.frameTooLarge
            }
            let frameSize = 4 + Int(size)
            guard buffer.count >= frameSize else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: frameSize)
            payloads.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeFirst(frameSize)
        }

        return payloads
    }
}

private func hasStrictNestedFields(method: String, object: [String: Any]) -> Bool {
    switch method {
    case "prepare_ghostty_binding":
        guard let params = object["params"] as? [String: Any], Set(params.keys) == ["target", "processes"],
              let target = params["target"] as? [String: Any],
              let processes = params["processes"] as? [[String: Any]] else { return false }
        return Set(target.keys) == ["applicationPID", "processStartToken", "windowId", "tabId", "terminalId", "nonce"]
            && processes.allSatisfy { Set($0.keys) == ["pid", "processStartToken"] }
    case "ghostty_terminal_views":
        guard let value = object["params"] else { return true }
        guard let params = value as? [String: Any], Set(params.keys) == ["conversationTitles"],
              params["conversationTitles"] is [String] else { return false }
        return true
    case "focus_ghostty_terminal":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let required: Set<String> = ["applicationPID", "processStartToken", "terminalId", "title", "cwd"]
        return required.isSubset(of: Set(target.keys))
            && Set(target.keys).isSubset(of: required.union(["titleUpdatesEnabled", "viewMode"]))
    case "resolve_ghostty_binding":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["nonce"],
              let nonce = params["nonce"] as? String else { return false }
        return nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
    case "focus_ghostty_binding":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let required: Set<String> = [
            "applicationPID", "processStartToken", "windowId", "tabId", "terminalId", "nonce",
        ]
        return Set(target.keys) == required
    case "present_pills":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys).contains("pills"),
              Set(params.keys).isSubset(of: [
                "pills", "navigatorPills", "usageGlances", "shortcutModifierFamily",
                "pillScreen", "fullScreenPolicy", "hotkeyTrigger", "customHotkeyCombo",
              ]),
              let pills = params["pills"] as? [[String: Any]] else { return false }
        let navigatorPills = params["navigatorPills"] as? [[String: Any]] ?? []
        let usageGlances = params["usageGlances"] as? [[String: Any]] ?? []
        let legacyPillKeys: Set<String> = [
            "id", "title", "phase", "priority", "accessibilityLabel",
        ]
        let detailedPillKeys = legacyPillKeys.union([
            "subtitle", "source", "project", "owner", "inspector", "lifecycleStatus",
            "attentionTier",
            "failureAlert", "defaultOverflowEligible", "completionUnseen",
        ])
        return (pills + navigatorPills).allSatisfy {
            let keys = Set($0.keys)
            return keys.isSuperset(of: legacyPillKeys)
                && keys.isSubset(of: detailedPillKeys)
                && ($0["inspector"].map(hasStrictInspectorFields) ?? true)
        }
            && usageGlances.allSatisfy(hasStrictUsageFields)
            && (params["pillScreen"].map(hasStrictPillScreenFields) ?? true)
    case "reconcile_notifications":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["notifications", "presentNew"],
              let notifications = params["notifications"] as? [[String: Any]] else {
            return false
        }
        let required: Set<String> = ["id", "sessionId", "title", "body", "sound"]
        let allowed = required.union(["subtitle", "toolUseId"])
        return notifications.allSatisfy {
            Set($0.keys).isSuperset(of: required) && Set($0.keys).isSubset(of: allowed)
        }
    case "reconcile_pi_restoration":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == [
                "candidates", "liveSessionIds", "removeCandidateSessionIds",
                "cleanTermination",
              ],
              let candidates = params["candidates"] as? [[String: Any]] else { return false }
        let required: Set<String> = ["sessionId", "sessionFile", "cwd", "pid", "tty"]
        let allowed = required.union(["sessionName"])
        return candidates.allSatisfy {
            Set($0.keys).isSuperset(of: required) && Set($0.keys).isSubset(of: allowed)
        }
    case "focus":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let keys = Set(target.keys)
        return keys == ["pid", "bundleIdentifier"]
            || keys == ["pid", "bundleIdentifier", "windowId"]
    case "open_codex_thread":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        return Set(target.keys) == ["pid", "home", "threadId"]
    case "open_claude_attach":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        return Set(target.keys) == ["cwd", "executable", "jobId"]
    case "open_ghostty_resume":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let required: Set<String> = [
            "attemptId", "provider", "sessionId", "cwd", "executable", "profileState", "nonce",
        ]
        let allowed = required.union(["configRoot", "settingsFile", "settingSources", "profileRef"])
        return Set(target.keys).isSuperset(of: required)
            && Set(target.keys).isSubset(of: allowed)
    case "read_process_provenance":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        return Set(target.keys) == ["pid", "provider", "processStartToken", "homeDirectory"]
    case "focus_terminal", "prepare_terminal":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys).isSubset(of: ["target", "conversationOnly"]),
              let target = params["target"] as? [String: Any] else { return false }
        if let policy = params["conversationOnly"] {
            guard let number = policy as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        }
        let keys = Set(target.keys)
        return keys == ["application", "tty", "cwd"]
            || keys == ["application", "pid", "tty", "cwd"]
            || keys == ["application", "pid", "processStartToken", "tty", "cwd"]
    case "send_terminal":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target", "text", "submit"],
              let target = params["target"] as? [String: Any] else { return false }
        let keys = Set(target.keys)
        return keys == ["application", "tty", "cwd"]
            || keys == ["application", "pid", "tty", "cwd"]
            || keys == ["application", "pid", "processStartToken", "tty", "cwd"]
    case "cancel_terminal":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let keys = Set(target.keys)
        return keys == ["application", "tty", "cwd"]
            || keys == ["application", "pid", "tty", "cwd"]
            || keys == ["application", "pid", "processStartToken", "tty", "cwd"]
    case "cycle_permission_mode":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let keys = Set(target.keys)
        return keys == ["application", "tty", "cwd"]
            || keys == ["application", "pid", "tty", "cwd"]
            || keys == ["application", "pid", "processStartToken", "tty", "cwd"]
    default:
        return true
    }
}

private struct WireRequest: Decodable {
    let version: Int
    let id: String
    let params: WireParameters?
}

private struct WireParameters: Decodable {
    let pills: [NativeHelperPill]?
    let navigatorPills: [NativeHelperPill]?
    let usageGlances: [NativeHelperUsageGlance]?
    let notifications: [NativeHelperNotification]?
    let presentNew: Bool?
    let piRestorationCandidates: [NativeHelperPiRestorationCandidate]?
    let liveSessionIds: [String]?
    let removeCandidateSessionIds: [String]?
    let cleanTermination: Bool?
    let shortcutModifierFamily: String?
    let pillScreen: NativeHelperPillScreen?
    let fullScreenPolicy: String?
    let hotkeyTrigger: String?
    let customHotkeyCombo: String?
    let target: NativeHelperFocusTarget?
    let codexThreadTarget: NativeHelperCodexThreadTarget?
    let claudeAttachTarget: NativeHelperClaudeAttachTarget?
    let ghosttyResumeTarget: NativeHelperGhosttyResumeTarget?
    let processProvenanceTarget: NativeHelperProcessProvenanceTarget?
    let terminalTarget: NativeHelperTerminalTarget?
    let conversationOnly: Bool?
    let ghosttyTerminalTarget: NativeHelperGhosttyTerminalView?
    let ghosttyBindingTarget: NativeHelperGhosttyBinding?
    let processes: [NativeHelperProcessIdentity]?
    let nonce: String?
    let conversationTitles: [String]?
    let text: String?
    let submit: Bool?
    let keys: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        keys = container.allKeys.map(\.stringValue)
        pills = try container.decodeIfPresent([NativeHelperPill].self, forKey: .init("pills"))
        navigatorPills = try container.decodeIfPresent(
            [NativeHelperPill].self,
            forKey: .init("navigatorPills")
        )
        usageGlances = try container.decodeIfPresent(
            [NativeHelperUsageGlance].self,
            forKey: .init("usageGlances")
        )
        notifications = try container.decodeIfPresent(
            [NativeHelperNotification].self,
            forKey: .init("notifications")
        )
        presentNew = try container.decodeIfPresent(Bool.self, forKey: .init("presentNew"))
        piRestorationCandidates = try container.decodeIfPresent(
            [NativeHelperPiRestorationCandidate].self,
            forKey: .init("candidates")
        )
        liveSessionIds = try container.decodeIfPresent(
            [String].self,
            forKey: .init("liveSessionIds")
        )
        removeCandidateSessionIds = try container.decodeIfPresent(
            [String].self,
            forKey: .init("removeCandidateSessionIds")
        )
        cleanTermination = try container.decodeIfPresent(
            Bool.self,
            forKey: .init("cleanTermination")
        )
        shortcutModifierFamily = try container.decodeIfPresent(
            String.self,
            forKey: .init("shortcutModifierFamily")
        )
        pillScreen = try container.decodeIfPresent(
            NativeHelperPillScreen.self,
            forKey: .init("pillScreen")
        )
        fullScreenPolicy = try container.decodeIfPresent(
            String.self,
            forKey: .init("fullScreenPolicy")
        )
        hotkeyTrigger = try container.decodeIfPresent(
            String.self,
            forKey: .init("hotkeyTrigger")
        )
        customHotkeyCombo = try container.decodeIfPresent(
            String.self,
            forKey: .init("customHotkeyCombo")
        )
        target = try? container.decodeIfPresent(NativeHelperFocusTarget.self, forKey: .init("target"))
        codexThreadTarget = try? container.decodeIfPresent(
            NativeHelperCodexThreadTarget.self, forKey: .init("target")
        )
        claudeAttachTarget = try? container.decodeIfPresent(
            NativeHelperClaudeAttachTarget.self, forKey: .init("target")
        )
        ghosttyResumeTarget = try? container.decodeIfPresent(
            NativeHelperGhosttyResumeTarget.self, forKey: .init("target")
        )
        processProvenanceTarget = try? container.decodeIfPresent(
            NativeHelperProcessProvenanceTarget.self, forKey: .init("target")
        )
        terminalTarget = try? container.decodeIfPresent(
            NativeHelperTerminalTarget.self,
            forKey: .init("target")
        )
        ghosttyTerminalTarget = try? container.decodeIfPresent(
            NativeHelperGhosttyTerminalView.self, forKey: .init("target")
        )
        ghosttyBindingTarget = try? container.decodeIfPresent(
            NativeHelperGhosttyBinding.self, forKey: .init("target")
        )
        processes = try container.decodeIfPresent([NativeHelperProcessIdentity].self, forKey: .init("processes"))
        conversationOnly = try container.decodeIfPresent(Bool.self, forKey: .init("conversationOnly"))
        nonce = try container.decodeIfPresent(String.self, forKey: .init("nonce"))
        conversationTitles = try container.decodeIfPresent([String].self, forKey: .init("conversationTitles"))
        text = try container.decodeIfPresent(String.self, forKey: .init("text"))
        submit = try container.decodeIfPresent(Bool.self, forKey: .init("submit"))
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private func hasStrictPillScreenFields(_ value: Any) -> Bool {
    guard let screen = value as? [String: Any],
          let mode = screen["mode"] as? String else { return false }
    return mode == "automatic"
        ? Set(screen.keys) == ["mode"]
        : mode == "specific"
            && (Set(screen.keys) == ["mode", "displayId", "name"]
                || Set(screen.keys) == ["mode", "displayId", "name", "displayUuid"])
}

private extension NativeHelperPillScreen {
    var isValid: Bool {
        switch mode {
        case .automatic:
            return displayId == nil && name == nil && displayUuid == nil
        case .specific:
            return displayId != nil
                && (name.map { !$0.isEmpty && $0.count <= 128 } ?? false)
                && (displayUuid.map { UUID(uuidString: $0) != nil } ?? true)
        }
    }
}

private extension String {
    var isValidRestorationSessionID: Bool {
        !isEmpty && count <= 512 && !contains("\0")
    }
}

private extension NativeHelperPiRestorationCandidate {
    var isValid: Bool {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let suffix = name.hasPrefix("ttys") ? name.dropFirst(4) : ""
        return !sessionId.isEmpty && sessionId.count <= 512 && !sessionId.contains("\0")
            && sessionFile.hasPrefix("/") && sessionFile.count <= 4_096
            && !sessionFile.contains("\0")
            && cwd.hasPrefix("/") && cwd.count <= 4_096 && !cwd.contains("\0")
            && (sessionName.map { !$0.isEmpty && $0.count <= 256 && !$0.contains("\0") } ?? true)
            && pid > 0
            && !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
            && tty.count <= 32
    }
}

private extension NativeHelperTerminalTarget {
    var isValid: Bool {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let suffix = name.hasPrefix("ttys") ? name.dropFirst(4) : ""
        return pid.map { $0 > 0 } == true
            && processStartToken.map { !$0.isEmpty && $0.count <= 256 && !$0.contains("\0") } == true
            && !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
            && tty.count <= 32
            && cwd.hasPrefix("/") && cwd.count <= 4_096
            && !cwd.contains("\0")
    }
}

private func hasStrictUsageFields(_ object: [String: Any]) -> Bool {
    let required: Set<String> = [
        "id", "label", "detail", "tone", "priority", "accessibilityLabel",
    ]
    let allowed = required.union([
        "heading", "width", "observedAt", "windows", "resetCreditsAvailable", "stale",
        "summary", "usageURL",
    ])
    guard Set(object.keys).isSuperset(of: required),
          Set(object.keys).isSubset(of: allowed) else { return false }
    let windows = object["windows"] as? [[String: Any]] ?? []
    return windows.allSatisfy {
        let keys = Set($0.keys)
        return keys.isSuperset(of: ["title", "remainingPercent"])
            && keys.isSubset(of: ["title", "remainingPercent", "tone", "resetsAt"])
    }
}

private func hasStrictInspectorFields(_ value: Any) -> Bool {
    guard let inspector = value as? [String: Any] else { return false }
    let required: Set<String> = [
        "status", "runtimeItems", "detailRows", "projectPath", "activityAt",
    ]
    let keys = Set(inspector.keys)
    guard keys.isSuperset(of: required), keys.isSubset(of: required.union(["context"])),
          let rows = inspector["detailRows"] as? [[String: Any]] else { return false }
    return rows.allSatisfy { Set($0.keys) == ["label", "value"] }
        && (inspector["context"].map {
            guard let context = $0 as? [String: Any] else { return false }
            return Set(context.keys) == ["usedLabel", "windowLabel", "percentage"]
        } ?? true)
}

private extension NativeHelperNotification {
    var isValid: Bool {
        !id.isEmpty && id.count <= 128
            && !sessionId.isEmpty && sessionId.count <= 512
            && !title.isEmpty && title.count <= 256
            && (subtitle.map { !$0.isEmpty && $0.count <= 512 } ?? true)
            && body.count <= 4_096
            && (toolUseId.map { !$0.isEmpty && $0.count <= 512 } ?? true)
    }
}

private extension NativeHelperPill {
    var isValid: Bool {
        !id.isEmpty && id.count <= 128
            && !title.isEmpty && title.count <= 256
            && (subtitle?.count ?? 0) <= 512
            && (source == nil || !(source?.isEmpty ?? true)) && (source?.count ?? 0) <= 128
            && (project == nil || !(project?.isEmpty ?? true)) && (project?.count ?? 0) <= 256
            && (owner == nil || !(owner?.isEmpty ?? true)) && (owner?.count ?? 0) <= 128
            && (inspector?.isValid ?? true)
            && !accessibilityLabel.isEmpty && accessibilityLabel.count <= 512
    }
}

private extension NativeHelperSessionInspector {
    var isValid: Bool {
        !status.isEmpty && status.count <= 64
            && (1...4).contains(runtimeItems.count)
            && runtimeItems.allSatisfy { !$0.isEmpty && $0.count <= 256 }
            && detailRows.count <= 8
            && detailRows.allSatisfy {
                !$0.label.isEmpty && $0.label.count <= 64
                    && !$0.value.isEmpty && $0.value.count <= 512
            }
            && !projectPath.isEmpty && projectPath.count <= 4_096
            && activityAt.count <= 64
            && NativeHelperTimestamp.parse(activityAt) != nil
            && (context?.isValid ?? true)
    }
}

private extension NativeHelperSessionInspectorContext {
    var isValid: Bool {
        !usedLabel.isEmpty && usedLabel.count <= 64
            && !windowLabel.isEmpty && windowLabel.count <= 64
            && (0...100).contains(percentage)
    }
}

private extension NativeHelperUsageWindow {
    var isValid: Bool {
        !title.isEmpty && title.count <= 64
            && (0...100).contains(remainingPercent)
            && (resetsAt.map {
                $0.count <= 64 && NativeHelperTimestamp.parse($0) != nil
            } ?? true)
    }
}

private extension NativeHelperUsageGlance {
    var isValid: Bool {
        ["codex", "claude", "copilot"].contains(id)
            && (heading.map { !$0.isEmpty && $0.count <= 64 } ?? true)
            && (width.map { $0.isFinite && (28...200).contains($0) } ?? true)
            && !label.isEmpty && label.count <= 128
            && !detail.isEmpty && detail.count <= 512
            && (summary.map { !$0.isEmpty && $0.count <= 256 } ?? true)
            && (usageURL.map { $0 == "https://github.com/settings/copilot" } ?? true)
            && !accessibilityLabel.isEmpty && accessibilityLabel.count <= 512
            && (observedAt.map {
                $0.count <= 64 && NativeHelperTimestamp.parse($0) != nil
            } ?? true)
            && (windows?.count ?? 0) <= 2
            && (windows ?? []).allSatisfy(\.isValid)
            && (resetCreditsAvailable.map { (0...1_000_000).contains($0) } ?? true)
    }
}

private struct SuccessEnvelope: Encodable {
    let version: Int
    let id: String
    let ok: Bool
    let result: ResultBody
}

private enum ResultBody: Encodable {
    case ghosttyTerminalViews([NativeHelperGhosttyTerminalView])
    case ghosttyResumeDispatched(NativeHelperGhosttyResumeDispatch)
    case processProvenance(NativeProcessProvenanceResult)
    case ghosttyBindingStatus(Bool)
    case ghosttyBinding(NativeHelperGhosttyBinding)
    case screenTopology([NativeHelperScreen])
    case accessibilityStatus(Bool)
    case notificationStatus(NativeHelperNotificationPermission)
    case accepted

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case .ghosttyTerminalViews(let views):
            try container.encode("ghostty_terminal_views", forKey: .init("type"))
            try container.encode(views, forKey: .init("views"))
        case .ghosttyResumeDispatched(let dispatch):
            try container.encode("ghostty_resume_dispatched", forKey: .init("type"))
            try container.encode(dispatch, forKey: .init("dispatch"))
        case .processProvenance(let result):
            try container.encode("process_provenance", forKey: .init("type"))
            switch result {
            case .available(let value):
                try container.encode("available", forKey: .init("state"))
                try container.encode(value, forKey: .init("value"))
            case .unavailable(let reason):
                try container.encode("unavailable", forKey: .init("state"))
                try container.encode(reason, forKey: .init("reason"))
            }
        case .ghosttyBindingStatus(let available):
            try container.encode("ghostty_binding_status", forKey: .init("type"))
            try container.encode(available, forKey: .init("available"))
        case .ghosttyBinding(let binding):
            try container.encode("ghostty_binding", forKey: .init("type"))
            try container.encode(binding, forKey: .init("binding"))
        case .screenTopology(let screens):
            try container.encode("screen_topology", forKey: .init("type"))
            try container.encode(screens, forKey: .init("screens"))
        case .accessibilityStatus(let trusted):
            try container.encode("accessibility_status", forKey: .init("type"))
            try container.encode(trusted, forKey: .init("trusted"))
        case .notificationStatus(let status):
            try container.encode("notification_status", forKey: .init("type"))
            try container.encode(status, forKey: .init("status"))
        case .accepted:
            try container.encode("accepted", forKey: .init("type"))
        }
    }
}

private struct ErrorEnvelope: Encodable {
    struct Body: Encodable {
        let code: NativeHelperErrorCode
        let message: String
        let reason: String?
        let systemCode: Int?
    }

    let version: Int
    let id: String
    let ok: Bool
    let error: Body
}
