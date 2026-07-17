import Foundation

public struct ToolUseCorrelationBuffer: Sendable {
    private struct Key: Hashable, Sendable {
        let sessionId: String
        let correlationKey: String
    }

    private struct Entry: Equatable, Sendable {
        let toolUseId: String
        let recordedAt: TimeInterval
    }

    private let maxEntries: Int
    private let maxAge: TimeInterval
    private var queues: [Key: [Entry]] = [:]
    private var keyByToolUseId: [String: Key] = [:]

    public init(maxEntries: Int = 512, maxAge: TimeInterval = 5 * 60) {
        self.maxEntries = max(1, maxEntries)
        self.maxAge = max(0, maxAge)
    }

    public var count: Int { keyByToolUseId.count }

    public mutating func record(
        sessionId: String,
        correlationKey: String,
        toolUseId: String,
        at now: TimeInterval
    ) {
        prune(at: now)
        remove(toolUseId: toolUseId)

        let key = Key(sessionId: sessionId, correlationKey: correlationKey)
        queues[key, default: []].append(Entry(toolUseId: toolUseId, recordedAt: now))
        keyByToolUseId[toolUseId] = key
        enforceBound()
    }

    public mutating func consume(
        sessionId: String,
        correlationKey: String,
        at now: TimeInterval
    ) -> String? {
        prune(at: now)
        let key = Key(sessionId: sessionId, correlationKey: correlationKey)
        guard var queue = queues[key], !queue.isEmpty else { return nil }

        let entry = queue.removeFirst()
        keyByToolUseId.removeValue(forKey: entry.toolUseId)
        if queue.isEmpty {
            queues.removeValue(forKey: key)
        } else {
            queues[key] = queue
        }
        return entry.toolUseId
    }

    public mutating func complete(toolUseId: String, at now: TimeInterval) {
        prune(at: now)
        remove(toolUseId: toolUseId)
    }

    public mutating func removeSession(_ sessionId: String, at now: TimeInterval) {
        prune(at: now)
        let keys = queues.keys.filter { $0.sessionId == sessionId }
        for key in keys {
            guard let entries = queues.removeValue(forKey: key) else { continue }
            for entry in entries {
                keyByToolUseId.removeValue(forKey: entry.toolUseId)
            }
        }
    }

    private mutating func prune(at now: TimeInterval) {
        for key in Array(queues.keys) {
            guard let entries = queues[key] else { continue }
            var kept: [Entry] = []
            kept.reserveCapacity(entries.count)
            for entry in entries {
                if now < entry.recordedAt || now - entry.recordedAt <= maxAge {
                    kept.append(entry)
                } else {
                    keyByToolUseId.removeValue(forKey: entry.toolUseId)
                }
            }
            if kept.isEmpty {
                queues.removeValue(forKey: key)
            } else {
                queues[key] = kept
            }
        }
    }

    private mutating func enforceBound() {
        while keyByToolUseId.count > maxEntries {
            guard let oldest = queues.compactMap({ key, queue -> (Key, Entry)? in
                queue.first.map { (key, $0) }
            }).min(by: { $0.1.recordedAt < $1.1.recordedAt }) else {
                return
            }
            remove(toolUseId: oldest.1.toolUseId)
        }
    }

    private mutating func remove(toolUseId: String) {
        guard let key = keyByToolUseId.removeValue(forKey: toolUseId),
              var queue = queues[key]
        else {
            return
        }
        queue.removeAll { $0.toolUseId == toolUseId }
        if queue.isEmpty {
            queues.removeValue(forKey: key)
        } else {
            queues[key] = queue
        }
    }
}
