import Foundation

enum CodexAgentVisorOwnershipStore {
    nonisolated private static let defaultsKey = "codexAgentVisorOwnedThreadIds"
    nonisolated private static let lock = NSLock()

    nonisolated static func claim(_ threadId: String) {
        guard !threadId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var ids = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        ids.insert(threadId)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: defaultsKey)
    }

    nonisolated static func isClaimed(_ threadId: String) -> Bool {
        guard !threadId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(threadId)
    }
}
