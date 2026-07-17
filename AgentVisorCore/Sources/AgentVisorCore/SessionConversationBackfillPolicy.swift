import Foundation

public enum SessionConversationBackfillPolicy {
    public static func shouldLoad(
        sessionName _: String?,
        firstUserMessage: String?,
        lastMessage: String?
    ) -> Bool {
        isBlank(firstUserMessage) && isBlank(lastMessage)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
