import AgentVisorCore
import AppKit
import Foundation
import UserNotifications

final class NativeNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let soundQueue = DispatchQueue(
        label: "AgentVisorNativeHelper.notification-sound",
        qos: .userInitiated
    )
    private let emit: (NativeHelperEvent) -> Void
    private var knownIdentifiers: Set<String> = []
    private let categoryID = "agent-visor.approval"
    private let approveActionID = "agent-visor.approve"
    private let denyActionID = "agent-visor.deny"

    init(emit: @escaping (NativeHelperEvent) -> Void) {
        self.emit = emit
        super.init()
        center.delegate = self
        let approve = UNNotificationAction(
            identifier: approveActionID,
            title: "Approve"
        )
        let deny = UNNotificationAction(
            identifier: denyActionID,
            title: "Deny",
            options: [.destructive]
        )
        center.setNotificationCategories([UNNotificationCategory(
            identifier: categoryID,
            actions: [approve, deny],
            intentIdentifiers: []
        )])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
            if let error {
                FileHandle.standardError.write(Data(
                    "Agent Visor notification authorization failed: \(error)\n".utf8
                ))
            }
            self?.center.getNotificationSettings { settings in
                self?.emit(.notificationPermission(Self.permission(settings.authorizationStatus)))
            }
        }
    }

    func status() -> NativeHelperNotificationPermission {
        let semaphore = DispatchSemaphore(value: 0)
        var result = NativeHelperNotificationPermission.notDetermined
        center.getNotificationSettings { settings in
            result = Self.permission(settings.authorizationStatus)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }

    func reconcile(
        _ notifications: [NativeHelperNotification],
        presentNew: Bool
    ) {
        let currentIdentifiers = Set(notifications.map(\.id))
        let resolved = Array(knownIdentifiers.subtracting(currentIdentifiers))
        center.removeDeliveredNotifications(withIdentifiers: resolved)
        center.removePendingNotificationRequests(withIdentifiers: resolved)

        let shouldPresent = presentNew && status() == .authorized && !agentVisorIsFrontmost
        let newNotifications = shouldPresent
            ? notifications.filter { !knownIdentifiers.contains($0.id) }
            : []
        knownIdentifiers = currentIdentifiers

        for notification in newNotifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.subtitle = notification.subtitle ?? ""
            content.body = notification.body
            content.userInfo = [
                "sessionId": notification.sessionId,
                "toolUseId": notification.toolUseId ?? "",
            ]
            if notification.toolUseId != nil {
                content.categoryIdentifier = categoryID
            }
            center.add(UNNotificationRequest(
                identifier: notification.id,
                content: content,
                trigger: nil
            ))
            if notification.sound != .none {
                soundQueue.async {
                    NSSound(named: NSSound.Name(notification.sound.rawValue))?.play()
                }
            }
        }
    }

    private var agentVisorIsFrontmost: Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return frontmost == "com.824zzy.AgentVisor" || frontmost == Bundle.main.bundleIdentifier
    }

    private static func permission(
        _ status: UNAuthorizationStatus
    ) -> NativeHelperNotificationPermission {
        switch status {
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let sessionId = info["sessionId"] as? String, !sessionId.isEmpty else { return }
        let toolUseId = (info["toolUseId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch response.actionIdentifier {
        case approveActionID:
            guard let toolUseId else { return }
            emit(.notificationAction(
                sessionId: sessionId,
                toolUseId: toolUseId,
                action: .approve
            ))
        case denyActionID:
            guard let toolUseId else { return }
            emit(.notificationAction(
                sessionId: sessionId,
                toolUseId: toolUseId,
                action: .deny
            ))
        case UNNotificationDefaultActionIdentifier:
            emit(.notificationAction(
                sessionId: sessionId,
                toolUseId: nil,
                action: .activate
            ))
        default:
            break
        }
    }
}
