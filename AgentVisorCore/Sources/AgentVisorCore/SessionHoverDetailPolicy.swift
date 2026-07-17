import Foundation

public struct SessionHoverDetailRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct SessionHoverContextPresentation: Equatable, Sendable {
    public let usedLabel: String
    public let windowLabel: String
    public let percentage: Int

    public init(usedLabel: String, windowLabel: String, percentage: Int) {
        self.usedLabel = usedLabel
        self.windowLabel = windowLabel
        self.percentage = percentage
    }
}

public struct SessionHoverDetailPresentation: Equatable, Sendable {
    public let statusTitle: String
    public let runtimeItems: [String]
    public let detailRows: [SessionHoverDetailRow]
    public let context: SessionHoverContextPresentation?
    public let shortcutLabel: String?

    public init(
        statusTitle: String,
        runtimeItems: [String],
        detailRows: [SessionHoverDetailRow],
        context: SessionHoverContextPresentation?,
        shortcutLabel: String? = nil
    ) {
        self.statusTitle = statusTitle
        self.runtimeItems = runtimeItems
        self.detailRows = detailRows
        self.context = context
        self.shortcutLabel = shortcutLabel
    }
}

public enum SessionHoverDetailPolicy {
    public static func sourceDisplayName(
        agentID: AgentID,
        terminalHost: TerminalHost?
    ) -> String {
        if agentID == .codex, terminalHost == .codexApp {
            return "Codex Desktop"
        }

        let agentName: String
        switch agentID {
        case .claudeCode: agentName = "Claude Code"
        case .auggie: agentName = "Auggie"
        case .codex: agentName = "Codex"
        case .cursor: agentName = "Cursor"
        }

        guard let terminalHost, terminalHost != .unknown else {
            return agentName
        }
        let hostName = HostMetadata.metadata(for: terminalHost).displayName
        guard hostName.caseInsensitiveCompare(agentName) != .orderedSame else {
            return agentName
        }
        return "\(agentName) · \(hostName)"
    }

    public static func presentation(
        phase: SessionInspectorPhase,
        sourceDisplayName: String,
        modelDisplayName: String?,
        effortLevel: String?,
        permissionMode: String?,
        codexApprovalPolicy: String?,
        codexSandboxPolicyType: String?,
        contextTokens: Int,
        contextWindowTokens: Int,
        shortcutModifierFamily: SessionShortcutModifierFamily = .off,
        shortcutPosition: Int? = nil
    ) -> SessionHoverDetailPresentation {
        var rows: [SessionHoverDetailRow] = []
        if let effort = reasoningDisplayName(effortLevel) {
            rows.append(SessionHoverDetailRow(label: "Reasoning", value: effort))
        }
        if let mode = permissionModeDisplayName(permissionMode) {
            rows.append(SessionHoverDetailRow(label: "Mode", value: mode))
        }

        let accessParts = [
            sandboxDisplayName(codexSandboxPolicyType),
            approvalDisplayName(codexApprovalPolicy),
        ].compactMap { $0 }
        if !accessParts.isEmpty {
            rows.append(SessionHoverDetailRow(label: "Access", value: accessParts.joined(separator: " · ")))
        }

        return SessionHoverDetailPresentation(
            statusTitle: statusTitle(for: phase),
            runtimeItems: [sourceDisplayName, modelDisplayName]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                },
            detailRows: rows,
            context: contextPresentation(
                tokens: contextTokens,
                windowTokens: contextWindowTokens
            ),
            shortcutLabel: shortcutPosition.flatMap {
                GlobalSessionShortcutPolicy.displayLabel(
                    forPosition: $0,
                    family: shortcutModifierFamily
                )
            }
        )
    }

    private static func statusTitle(for phase: SessionInspectorPhase) -> String {
        switch phase {
        case .needsAttention: return "Needs attention"
        case .ready: return "Ready"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .recent: return "Recent"
        case .ended: return "Ended"
        }
    }

    private static func reasoningDisplayName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "xhigh": return "XHigh"
        case "xlow": return "XLow"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private static func sandboxDisplayName(_ raw: String?) -> String? {
        switch raw {
        case "danger-full-access": return "Full access"
        case "workspace-write": return "Workspace write"
        case "read-only": return "Read only"
        default: return nil
        }
    }

    private static func permissionModeDisplayName(_ raw: String?) -> String? {
        switch raw {
        case "acceptEdits": return "Accept edits"
        case "plan": return "Plan"
        case "bypassPermissions": return "Bypass permissions"
        case "auto": return "Auto"
        default: return nil
        }
    }

    private static func approvalDisplayName(_ raw: String?) -> String? {
        switch raw {
        case "never": return "Never ask"
        case "on-request": return "Ask when needed"
        case "on-failure": return "Ask on failure"
        case "untrusted": return "Ask for untrusted commands"
        default: return nil
        }
    }

    private static func contextPresentation(
        tokens: Int,
        windowTokens: Int
    ) -> SessionHoverContextPresentation? {
        guard tokens > 0, windowTokens > 0 else { return nil }
        let percentage = min(100, max(0, Int(
            (Double(tokens) / Double(windowTokens) * 100).rounded()
        )))
        return SessionHoverContextPresentation(
            usedLabel: tokenLabel(tokens),
            windowLabel: tokenLabel(windowTokens),
            percentage: percentage
        )
    }

    private static func tokenLabel(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }
}
