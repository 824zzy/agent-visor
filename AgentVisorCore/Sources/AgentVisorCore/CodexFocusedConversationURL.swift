import Foundation

public enum CodexFocusedConversationURL {
    public static func threadId(_ value: String) -> String? {
        guard let url = URL(string: value), url.query == nil, url.fragment == nil else { return nil }
        let components = url.path.split(separator: "/").map(String.init)
        let id: String?
        if url.scheme == "codex", url.host == "threads", components.count == 1 {
            id = components.last
        } else if url.scheme == "app", url.host == "-",
                  (components.count == 2 && components.first == "local"
                   || components.count == 3 && components.prefix(2) == ["hotkey-window", "thread"]) {
            id = components.last
        } else { id = nil }
        return id.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }
}
