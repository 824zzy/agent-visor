import Darwin
import Foundation

/// Byte-level line iterator over JSONL data. Designed for the hot path on
/// huge transcripts (100+ MB): never materializes a String for the whole
/// buffer and uses `memchr` to locate line boundaries instead of advancing a
/// generic Collection index once per byte. Each `next()` returns a `Data`
/// slice that callers decode only when needed.
///
/// Strips a trailing `\r` on each line so CRLF transcripts (uncommon for
/// JSONL but cheap to handle) don't leak the carriage return into the JSON
/// parser. Empty lines (consecutive `\n`) are skipped.
public struct JSONLLineIterator: IteratorProtocol, Sequence {
    public typealias Element = Data

    private let data: Data
    private var cursorOffset: Int

    public init(data: Data) {
        self.data = data
        self.cursorOffset = 0
    }

    public mutating func next() -> Data? {
        let byteCount = data.count
        while cursorOffset < byteCount {
            let lineStartOffset = cursorOffset
            let lineEndOffset = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return byteCount
                }
                let searchStart = baseAddress.advanced(by: lineStartOffset)
                let remaining = byteCount - lineStartOffset
                guard let newline = memchr(searchStart, 0x0A, remaining) else {
                    return byteCount
                }
                return lineStartOffset + searchStart.distance(to: newline)
            }

            cursorOffset = lineEndOffset < byteCount
                ? lineEndOffset + 1
                : byteCount

            var trimmedEndOffset = lineEndOffset
            if trimmedEndOffset > lineStartOffset {
                let previous = data.index(
                    data.startIndex,
                    offsetBy: trimmedEndOffset - 1
                )
                if data[previous] == 0x0D {
                    trimmedEndOffset -= 1
                }
            }

            guard trimmedEndOffset > lineStartOffset else {
                continue
            }
            let start = data.index(data.startIndex, offsetBy: lineStartOffset)
            let end = data.index(data.startIndex, offsetBy: trimmedEndOffset)
            return data[start..<end]
        }
        return nil
    }
}
