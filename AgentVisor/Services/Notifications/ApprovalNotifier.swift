//
//  ApprovalNotifier.swift
//  AgentVisor
//
//  Coordinates Agent Visor's local notifications and routes their actions.
//

import AppKit
import AgentVisorCore
import Combine
import Foundation
import os.log
import UserNotifications

@MainActor
final class ApprovalNotifier: NSObject {
    static let shared = ApprovalNotifier()

    private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ApprovalNotifier")

    /// Dedupe keys we've already notified for, driven by
    /// `AttentionReconciler`. Covers both approvals (keyed by toolUseId)
    /// and your-turn events (keyed by a per-turn token). A key clears when
    /// its attention resolves, so the same tool/turn re-fires next time.
    private var notifiedKeys: Set<String> = []

    private let categoryID = "cv.approval.category"
    private let approveActionID = "cv.approval.approve"
    private let denyActionID = "cv.approval.deny"

    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategory()
        requestAuthorization()

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.reconcile(with: sessions)
            }
            .store(in: &cancellables)

        logger.info("ApprovalNotifier started")
    }

    // MARK: - Permission setup

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                Self.logNotificationError(error, context: "authorization")
                return
            }
            self?.logger.info("notification auth granted=\(granted, privacy: .public)")
        }
    }

    private func registerCategory() {
        let approve = UNNotificationAction(
            identifier: approveActionID,
            title: "Approve",
            options: [.foreground]
        )
        let deny = UNNotificationAction(
            identifier: denyActionID,
            title: "Deny",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func notifyUpdateAvailable(version: String, isUserInitiated: Bool) {
        let canonicalVersion = UpdateNotificationPolicy.canonicalVersion(version)
        guard UpdateNotificationPolicy.shouldNotify(
            version: canonicalVersion,
            lastNotifiedVersion: AppSettings.lastNotifiedUpdateVersion,
            isUserInitiated: isUserInitiated
        ), let descriptor = UpdateNotificationPolicy.descriptor(version: canonicalVersion) else { return }

        AppSettings.lastNotifiedUpdateVersion = canonicalVersion

        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        content.sound = nil
        content.userInfo = ["route": descriptor.route]
        let request = UNNotificationRequest(
            identifier: descriptor.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("update notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Reconciliation

    private func reconcile(with sessions: [SessionState]) {
        // Build the current cross-agent attention set: a session needs
        // attention when it's blocked on an approval OR has finished its
        // turn (your move). Carry per-session context for the notifier.
        var items: [AttentionItem] = []
        var approvalCtx: [String: PermissionContext] = [:]
        var meta: [String: (title: String, agent: AgentID)] = [:]
        for state in sessions {
            meta[state.sessionId] = (state.displayTitle, state.agentID)
            switch state.phase {
            case .waitingForApproval(let ctx):
                items.append(AttentionItem(
                    sessionId: state.sessionId,
                    kind: .approval(toolUseId: ctx.toolUseId)
                ))
                approvalCtx[state.sessionId] = ctx
            case .waitingForInput:
                // Token = transcript length so a NEW completed turn re-fires
                // instead of being swallowed as a duplicate of the last.
                items.append(AttentionItem(
                    sessionId: state.sessionId,
                    kind: .yourTurn(turnToken: "\(state.chatItems.count)")
                ))
            default:
                break
            }
        }

        let result = AttentionReconciler.reconcile(
            current: items,
            previouslyNotified: notifiedKeys
        )
        notifiedKeys = result.currentKeys

        // Retract notifications whose attention resolved.
        if !result.resolvedKeys.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: result.resolvedKeys)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: result.resolvedKeys)
        }

        // Don't pester the user when agent-visor itself is focused — the
        // pills + inline rows are the primary surface there. The key is
        // still recorded above, so it won't fire late after they leave.
        let suppress = NSApp.isActive && NSApp.keyWindow != nil

        for item in result.newItems {
            guard let info = meta[item.sessionId] else { continue }
            if suppress {
                logger.info("skip notif (app active+key) for \(item.dedupeKey, privacy: .public)")
                continue
            }
            switch item.kind {
            case .approval:
                if let ctx = approvalCtx[item.sessionId] {
                    schedule(
                        for: info.title,
                        ctx: ctx,
                        sessionId: item.sessionId,
                        identifier: item.dedupeKey
                    )
                }
            case .yourTurn:
                scheduleYourTurn(
                    title: info.title,
                    agent: info.agent,
                    sessionId: item.sessionId,
                    identifier: item.dedupeKey
                )
            }
        }

        updateDockBadge(count: result.totalCount)
    }

    /// "Your turn" — the agent finished and is waiting on the user. No
    /// approve/deny actions (nothing to decide); tapping opens the window.
    private func scheduleYourTurn(
        title: String,
        agent: AgentID,
        sessionId: String,
        identifier: String
    ) {
        let payload = UNMutableNotificationContent()
        payload.title = title
        payload.subtitle = "\(agentName(agent)) · your turn"
        payload.body = "Finished — waiting on you."
        payload.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: payload,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logNotificationError(error, context: "your-turn post \(identifier)")
            }
        }
    }

    private func agentName(_ agent: AgentID) -> String {
        switch agent {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .cursor:     return "Cursor"
        case .auggie:     return "Auggie"
        }
    }

    private func schedule(for displayTitle: String, ctx: PermissionContext, sessionId: String, identifier: String) {
        let content = ApprovalNotificationContent.make(
            displayTitle: displayTitle,
            toolName: ctx.toolName,
            input: ctx.formattedInput ?? ""
        )
        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.subtitle = content.subtitle
        payload.body = content.body
        payload.categoryIdentifier = categoryID
        payload.userInfo = [
            "sessionId": sessionId,
            "toolUseId": ctx.toolUseId,
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: payload,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logNotificationError(error, context: "approval post \(identifier)")
            }
        }
    }

    nonisolated private static func logNotificationError(_ error: Error, context: String) {
        let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ApprovalNotifier")
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain && nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
            logger.notice("notification \(context, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        logger.error("notification \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    private func updateDockBadge(count: Int) {
        let label = count == 0 ? "" : "\(count)"
        NSApp.dockTile.badgeLabel = label
    }
}

extension ApprovalNotifier: UNUserNotificationCenterDelegate {
    /// Show our notifications even when the app is foregrounded —
    /// users running with the window minimized still benefit from the
    /// banner. The dock badge takes care of the unread count.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.userInfo["route"] as? String == "update-details" {
            completionHandler([.banner])
            return
        }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let route = userInfo["route"] as? String
        let sessionId = userInfo["sessionId"] as? String
        let _ = userInfo["toolUseId"] as? String

        Task { @MainActor in
            defer { completionHandler() }
            if route == "update-details" {
                AppDelegate.shared?.openUpdateDetails(checkNow: false)
                return
            }
            guard let sessionId else { return }
            let monitor = AppDelegate.shared?.sessionMonitor
            switch actionID {
            case "cv.approval.approve":
                monitor?.approvePermission(sessionId: sessionId)
            case "cv.approval.deny":
                monitor?.denyPermission(sessionId: sessionId, reason: nil)
            default:
                AppDelegate.shared?.openSessionInMainWindow(sessionId)
            }
        }
    }
}
