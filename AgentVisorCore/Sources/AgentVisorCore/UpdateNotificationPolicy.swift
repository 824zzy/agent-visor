import Foundation

public struct UpdateNotificationDescriptor: Equatable, Sendable {
    public let identifier: String
    public let route: String
    public let title: String
    public let body: String

    public init(identifier: String, route: String, title: String, body: String) {
        self.identifier = identifier
        self.route = route
        self.title = title
        self.body = body
    }
}

public enum UpdateNotificationPolicy {
    public static func shouldNotify(
        version: String,
        lastNotifiedVersion: String?,
        isUserInitiated: Bool
    ) -> Bool {
        let version = canonicalVersion(version)
        guard !version.isEmpty, !isUserInitiated else { return false }
        return version != lastNotifiedVersion.map(canonicalVersion)
    }

    public static func canonicalVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("v") else { return trimmed }
        return String(trimmed.dropFirst())
    }

    public static func descriptor(version: String) -> UpdateNotificationDescriptor? {
        let version = canonicalVersion(version)
        guard !version.isEmpty else { return nil }
        return UpdateNotificationDescriptor(
            identifier: "cv.update.\(version)",
            route: "update-details",
            title: "Agent Visor v\(version) is available",
            body: "Open update details to review and install it."
        )
    }
}
