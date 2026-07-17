import Foundation

public struct CodexTurnContextScanState: Equatable, Sendable {
    public let latestRecord: Data?

    fileprivate let path: String
    fileprivate let fileByteCount: UInt64
    fileprivate let nextReadOffset: UInt64
}

public enum CodexTurnContextFileScanner {
    public static let defaultChunkBytes = 256 * 1024
    public static let defaultMaximumRecordBytes = 256 * 1024

    public static func scan(
        path: String,
        previous: CodexTurnContextScanState? = nil,
        chunkBytes: Int = defaultChunkBytes,
        maximumRecordBytes: Int = defaultMaximumRecordBytes
    ) -> CodexTurnContextScanState? {
        guard chunkBytes > 0,
              maximumRecordBytes > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber,
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        let fileByteCount = sizeNumber.uint64Value
        if let previous,
           previous.path == path,
           fileByteCount >= previous.fileByteCount {
            if fileByteCount == previous.fileByteCount {
                return previous
            }
            guard let incremental = scanForward(
                handle: handle,
                from: min(previous.nextReadOffset, previous.fileByteCount),
                to: fileByteCount,
                priorLatestRecord: previous.latestRecord,
                chunkBytes: chunkBytes,
                maximumRecordBytes: maximumRecordBytes
            ) else {
                return nil
            }
            return CodexTurnContextScanState(
                latestRecord: incremental.latestRecord,
                path: path,
                fileByteCount: fileByteCount,
                nextReadOffset: incremental.nextReadOffset
            )
        }

        let latestRecord = scanBackward(
            handle: handle,
            fileByteCount: fileByteCount,
            chunkBytes: chunkBytes,
            maximumRecordBytes: maximumRecordBytes
        )
        guard let trailing = scanForward(
            handle: handle,
            from: fileByteCount > UInt64(maximumRecordBytes)
                ? fileByteCount - UInt64(maximumRecordBytes)
                : 0,
            to: fileByteCount,
            priorLatestRecord: latestRecord,
            chunkBytes: chunkBytes,
            maximumRecordBytes: maximumRecordBytes
        ) else {
            return nil
        }

        return CodexTurnContextScanState(
            latestRecord: trailing.latestRecord,
            path: path,
            fileByteCount: fileByteCount,
            nextReadOffset: trailing.nextReadOffset
        )
    }

    private struct ForwardScanResult {
        let latestRecord: Data?
        let nextReadOffset: UInt64
    }

    private static func scanForward(
        handle: FileHandle,
        from startOffset: UInt64,
        to endOffset: UInt64,
        priorLatestRecord: Data?,
        chunkBytes: Int,
        maximumRecordBytes: Int
    ) -> ForwardScanResult? {
        guard startOffset <= endOffset else { return nil }
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }

        var latestRecord = priorLatestRecord
        var pending = Data()
        var pendingStartOffset = startOffset
        var pendingIsOversized = false
        var position = startOffset

        while position < endOffset {
            let readCount = Int(min(UInt64(chunkBytes), endOffset - position))
            let block: Data
            do {
                block = (try handle.read(upToCount: readCount)) ?? Data()
            } catch {
                return nil
            }
            guard !block.isEmpty else { return nil }

            let blockStartOffset = position
            var segmentStart = block.startIndex
            while segmentStart < block.endIndex,
                  let newline = block[segmentStart...].firstIndex(of: 0x0A) {
                append(
                    block[segmentStart..<newline],
                    to: &pending,
                    isOversized: &pendingIsOversized,
                    maximumRecordBytes: maximumRecordBytes
                )
                if !pendingIsOversized,
                   let record = turnContextRecord(from: pending) {
                    latestRecord = record
                }
                pending.removeAll(keepingCapacity: true)
                pendingIsOversized = false
                segmentStart = block.index(after: newline)
                pendingStartOffset = blockStartOffset
                    + UInt64(block.distance(from: block.startIndex, to: segmentStart))
            }

            if segmentStart < block.endIndex {
                if pending.isEmpty && !pendingIsOversized {
                    pendingStartOffset = blockStartOffset
                        + UInt64(block.distance(from: block.startIndex, to: segmentStart))
                }
                append(
                    block[segmentStart..<block.endIndex],
                    to: &pending,
                    isOversized: &pendingIsOversized,
                    maximumRecordBytes: maximumRecordBytes
                )
            }
            position += UInt64(block.count)
        }

        if !pendingIsOversized,
           !pending.isEmpty,
           isCompleteJSONObject(pending) {
            if let record = turnContextRecord(from: pending) {
                latestRecord = record
            }
            pendingStartOffset = endOffset
        } else if pendingIsOversized {
            pendingStartOffset = endOffset > UInt64(maximumRecordBytes)
                ? endOffset - UInt64(maximumRecordBytes)
                : 0
        } else if pending.isEmpty {
            pendingStartOffset = endOffset
        }

        return ForwardScanResult(
            latestRecord: latestRecord,
            nextReadOffset: pendingStartOffset
        )
    }

    private static func scanBackward(
        handle: FileHandle,
        fileByteCount: UInt64,
        chunkBytes: Int,
        maximumRecordBytes: Int
    ) -> Data? {
        var endOffset = fileByteCount
        var suffix = Data()
        var suffixIsOversized = false

        while endOffset > 0 {
            let startOffset = endOffset > UInt64(chunkBytes)
                ? endOffset - UInt64(chunkBytes)
                : 0
            let block: Data
            do {
                try handle.seek(toOffset: startOffset)
                block = (try handle.read(upToCount: Int(endOffset - startOffset))) ?? Data()
            } catch {
                return nil
            }
            guard !block.isEmpty else { return nil }

            var segmentEnd = block.endIndex
            while let newline = block[..<segmentEnd].lastIndex(of: 0x0A) {
                let segmentStart = block.index(after: newline)
                if !suffixIsOversized {
                    var candidate = Data(block[segmentStart..<segmentEnd])
                    append(
                        suffix,
                        to: &candidate,
                        isOversized: &suffixIsOversized,
                        maximumRecordBytes: maximumRecordBytes
                    )
                    if !suffixIsOversized,
                       let record = turnContextRecord(from: candidate) {
                        return record
                    }
                }
                suffix.removeAll(keepingCapacity: true)
                suffixIsOversized = false
                segmentEnd = newline
            }

            if !suffixIsOversized {
                var joined = Data(block[..<segmentEnd])
                append(
                    suffix,
                    to: &joined,
                    isOversized: &suffixIsOversized,
                    maximumRecordBytes: maximumRecordBytes
                )
                suffix = suffixIsOversized ? Data() : joined
            }
            endOffset = startOffset
        }

        guard !suffixIsOversized else { return nil }
        return turnContextRecord(from: suffix)
    }

    private static func append<C: Collection>(
        _ bytes: C,
        to data: inout Data,
        isOversized: inout Bool,
        maximumRecordBytes: Int
    ) where C.Element == UInt8 {
        guard !isOversized else { return }
        guard data.count + bytes.count <= maximumRecordBytes else {
            data.removeAll(keepingCapacity: false)
            isOversized = true
            return
        }
        data.append(contentsOf: bytes)
    }

    private static func turnContextRecord(from data: Data) -> Data? {
        var record = data
        if record.last == 0x0D {
            record.removeLast()
        }
        guard record.range(of: Data(#""turn_context""#.utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              json["type"] as? String == "turn_context" else {
            return nil
        }
        return record
    }

    private static func isCompleteJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
