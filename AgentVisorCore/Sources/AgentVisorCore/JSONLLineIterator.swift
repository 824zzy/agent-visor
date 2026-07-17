import Foundation

/// Byte-level line iterator over JSONL data. Designed for the hot path on
/// huge transcripts (100+ MB): never materializes a String for the whole
/// buffer, never copies bytes for the line slice. Each `next()` returns a
/// `Data` view (which is `Data.SubSequence`) that callers can prefilter
/// via `range(of:)` before paying the JSONDecoder cost.
///
/// Strips a trailing `\r` on each line so CRLF transcripts (uncommon for
/// JSONL but cheap to handle) don't leak the carriage return into the
/// JSON parser. Empty lines (consecutive `\n`) are skipped.
public struct JSONLLineIterator: IteratorProtocol, Sequence {
    public typealias Element = Data

    private let data: Data
    private var cursor: Data.Index

    public init(data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    public mutating func next() -> Data? {
        let end = data.endIndex
        while cursor < end {
            let lineStart = cursor
            // Scan forward to the next LF (0x0A) or end of buffer.
            var lineEnd = lineStart
            while lineEnd < end && data[lineEnd] != 0x0A {
                data.formIndex(after: &lineEnd)
            }

            // Compute next-cursor BEFORE we trim CR — cursor must skip past
            // the LF we found (or sit at end if we ran off the buffer).
            if lineEnd < end {
                cursor = data.index(after: lineEnd)
            } else {
                cursor = end
            }

            // Strip a single trailing CR for CRLF resilience.
            var trimmedEnd = lineEnd
            if trimmedEnd > lineStart && data[data.index(before: trimmedEnd)] == 0x0D {
                trimmedEnd = data.index(before: trimmedEnd)
            }

            // Skip blank lines so callers don't pay the prefilter cost on them.
            if trimmedEnd > lineStart {
                return data[lineStart..<trimmedEnd]
            }
            // else: empty line, loop and try again from updated cursor.
        }
        return nil
    }
}
