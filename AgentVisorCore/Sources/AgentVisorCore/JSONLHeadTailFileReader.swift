import Foundation

public enum JSONLHeadTailFileReader {
    public static let defaultSmallFileThreshold: UInt64 = 512 * 1024
    public static let defaultHeadBytes: UInt64 = 256 * 1024
    public static let defaultTailBytes: UInt64 = 256 * 1024

    public static func read(
        path: String,
        smallFileThreshold: UInt64 = defaultSmallFileThreshold,
        headBytes: UInt64 = defaultHeadBytes,
        tailBytes: UInt64 = defaultTailBytes
    ) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return nil
        }

        let fileSize = sizeNumber.uint64Value
        if fileSize <= smallFileThreshold {
            return FileManager.default.contents(atPath: path)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let headData: Data
        do {
            try handle.seek(toOffset: 0)
            headData = (try handle.read(upToCount: Int(min(headBytes, fileSize)))) ?? Data()
        } catch {
            return nil
        }

        let tailStart = fileSize > tailBytes ? fileSize - tailBytes : 0
        let tailData: Data
        do {
            try handle.seek(toOffset: tailStart)
            tailData = (try handle.readToEnd()) ?? Data()
        } catch {
            return nil
        }

        return slice(head: headData, tail: tailData, tailStartedAtBoundary: tailStart == 0)
    }

    public static func slice(
        data: Data,
        smallFileThreshold: UInt64 = defaultSmallFileThreshold,
        headBytes: UInt64 = defaultHeadBytes,
        tailBytes: UInt64 = defaultTailBytes
    ) -> Data {
        let fileSize = UInt64(data.count)
        guard fileSize > smallFileThreshold else { return data }

        let head = data.prefix(Int(min(headBytes, fileSize)))
        let tailStart = fileSize > tailBytes ? data.count - Int(tailBytes) : 0
        let tail = data.suffix(from: tailStart)
        return slice(
            head: Data(head),
            tail: Data(tail),
            tailStartedAtBoundary: tailStart == 0
        )
    }

    private static func slice(head: Data, tail: Data, tailStartedAtBoundary: Bool) -> Data {
        var result = Data()
        result.append(cleanHead(head))
        if !result.isEmpty {
            result.append(0x0A)
        }
        result.append(cleanTail(tail, startedAtBoundary: tailStartedAtBoundary))
        return result
    }

    private static func cleanHead(_ data: Data) -> Data {
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return data
        }
        return data[..<lastNewline]
    }

    private static func cleanTail(_ data: Data, startedAtBoundary: Bool) -> Data {
        if startedAtBoundary { return data }
        guard let firstNewline = data.firstIndex(of: 0x0A) else {
            return Data()
        }
        let start = data.index(after: firstNewline)
        return data[start...]
    }
}
