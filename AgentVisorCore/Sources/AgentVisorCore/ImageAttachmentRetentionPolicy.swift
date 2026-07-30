import Foundation

public enum ImageAttachmentRetentionPolicy {
    public static let staleFileAge: TimeInterval = 24 * 60 * 60

    public static func cleanupDelay(
        for route: ImageSubmissionRoute
    ) -> TimeInterval? {
        switch route {
        case .terminalPathPrompt:
            return 24 * 60 * 60
        case .appServerLocalImage, .terminalAttachment:
            return 60
        case .unavailable:
            return nil
        }
    }
}
