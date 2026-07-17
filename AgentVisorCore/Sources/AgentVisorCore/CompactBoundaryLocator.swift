import Foundation

/// Locates the LAST `compact_boundary` line in a JSONL transcript Data.
///
/// Mirrors claude-code-main's pre-compact skip optimization: for huge
/// transcripts (>5 MB), every byte before the last compact boundary is
/// stale context that doesn't render in the chat UI. Skipping it at the
/// byte level avoids JSON-parsing tens of megabytes of dead history.
///
/// The marker substring `"compact_boundary"` can appear inside user
/// content (someone pastes a doc snippet), so we never trust a bytes-only
/// match — every candidate line is JSON-parsed and the
/// `type:"system",subtype:"compact_boundary"` shape is confirmed.
public enum CompactBoundaryLocator {

    private static let markerBytes = Data("\"compact_boundary\"".utf8)

    /// Returns the byte offset where the LAST compact_boundary line starts,
    /// or nil if no real boundary line exists in `data`.
    public static func findLastBoundaryOffset(in data: Data) -> UInt64? {
        // Walk forward through candidate marker hits, recording every
        // confirmed boundary line; the LAST one wins. Forward is simpler
        // to reason about than reverse and avoids re-running JSON parse on
        // the same line twice. The marker is small (~20 B) and rare; for a
        // 333 MB transcript with a handful of compacts, this scans most of
        // the file once via Data.range(of:in:) hops.
        let searchEnd = data.endIndex
        var lastConfirmedOffset: UInt64? = nil

        var cursor = data.startIndex
        while cursor < searchEnd {
            guard let hit = data.range(of: Self.markerBytes, options: [], in: cursor..<searchEnd) else {
                break
            }

            // Locate the enclosing line bounds. Scan back to the previous LF,
            // forward to the next LF (or end of buffer).
            var lineStart = hit.lowerBound
            while lineStart > data.startIndex {
                let prev = data.index(before: lineStart)
                if data[prev] == 0x0A { break }
                lineStart = prev
            }
            var lineEnd = hit.upperBound
            while lineEnd < data.endIndex && data[lineEnd] != 0x0A {
                data.formIndex(after: &lineEnd)
            }

            // Confirm via JSON shape. False positives (marker inside user
            // content) are silently skipped.
            if isCompactBoundaryLine(data[lineStart..<lineEnd]) {
                lastConfirmedOffset = UInt64(data.distance(from: data.startIndex, to: lineStart))
            }

            // Continue scanning AFTER the current line so a second boundary
            // overrides the first.
            cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
        }
        return lastConfirmedOffset
    }

    private static func isCompactBoundaryLine(_ slice: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] else {
            return false
        }
        return (json["type"] as? String) == "system" &&
               (json["subtype"] as? String) == "compact_boundary"
    }

    /// Chunked reverse-scan over a file on disk. Reads from the END of the
    /// file backwards in `chunkSize` increments, looking for the marker
    /// bytes. As soon as a confirmed boundary is found, returns its
    /// line-start offset. For a 333 MB file with the last boundary 1.4 MB
    /// from the end, this reads ~2 MB total instead of the full file.
    ///
    /// Returns nil if no boundary exists or if the file is empty.
    public static func findLastBoundaryOffset(at filePath: String, fileSize: UInt64, chunkSize: Int = 2 * 1024 * 1024) -> UInt64? {
        guard fileSize > 0,
              let fh = FileHandle(forReadingAtPath: filePath) else {
            return nil
        }
        defer { try? fh.close() }

        // Read fixed-size windows from end backwards. Overlap successive
        // windows by `markerBytes.count` so a boundary line straddling a
        // window boundary isn't missed.
        let overlap = max(markerBytes.count, 1)
        let window = max(chunkSize, overlap + 256)

        var windowEnd = fileSize
        // We carry one chunk of "later" bytes appended to the next read so
        // a hit's line-end can be located even if the LF is in the next
        // window. For correctness on huge files we keep the carry bounded.
        var carry = Data()

        while windowEnd > 0 {
            let readSize = min(UInt64(window), windowEnd)
            let readStart = windowEnd - readSize
            do {
                try fh.seek(toOffset: readStart)
            } catch {
                return nil
            }
            guard let chunkData = try? fh.read(upToCount: Int(readSize)) else {
                return nil
            }

            // Combine with carry from the previous (later) window.
            var buf = chunkData
            buf.append(carry)
            // Run the in-memory locator on this slice. If we get a hit,
            // its offset is relative to `readStart`.
            if let relativeOffset = findLastBoundaryOffset(in: buf) {
                return readStart + relativeOffset
            }

            // Slide the window backwards. The new carry is the overlap
            // region from the start of the buf we just searched, so a
            // boundary straddling the seam is found on the next iteration.
            let carryLen = min(overlap, buf.count)
            carry = buf.prefix(carryLen)
            windowEnd = readStart
        }
        return nil
    }
}
