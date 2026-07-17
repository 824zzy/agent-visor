import XCTest
@testable import AgentVisorCore

/// Locator for the LAST `compact_boundary` line in a JSONL transcript.
/// For huge sessions claude-code-main truncates everything before this
/// offset; we mirror that to skip parsing pre-compact bubbles entirely.
/// Must JSON-confirm `type:"system",subtype:"compact_boundary"` because
/// the marker substring can appear inside user-pasted content as a
/// false positive.
final class CompactBoundaryLocatorTests: XCTestCase {

    func testEmptyDataReturnsNil() {
        // Given an empty buffer
        let data = Data()
        // When we locate the last boundary
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then there is no boundary
        XCTAssertNil(offset)
    }

    func testNoBoundaryMarkerReturnsNil() {
        // Given a buffer with normal user/assistant turns and no compact
        let data = Data("""
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","message":{"content":"hello"}}
        """.utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then nil
        XCTAssertNil(offset)
    }

    func testOneBoundaryReturnsItsLineStartOffset() {
        // Given a buffer with one compact_boundary line
        let prefix = "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n"
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let suffix = "{\"type\":\"user\",\"message\":{\"content\":\"after\"}}\n"
        let data = Data((prefix + boundary + suffix).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then the offset is the start of the boundary line (just after the prefix)
        XCTAssertEqual(offset, UInt64(Data(prefix.utf8).count))
    }

    func testMultipleBoundariesReturnsLastOne() {
        // Given a buffer with two compact_boundary lines
        let chunk = "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n"
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let combined = chunk + boundary + chunk + boundary + chunk
        let data = Data(combined.utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then the offset is the start of the SECOND boundary line
        let expected = UInt64((chunk + boundary + chunk).utf8.count)
        XCTAssertEqual(offset, expected)
    }

    func testBoundaryAtByteZeroReturnsZero() {
        // Given a buffer whose first line is the boundary
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let after = "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n"
        let data = Data((boundary + after).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then offset is 0
        XCTAssertEqual(offset, 0)
    }

    func testBoundaryAsLastLineWithoutTrailingNewlineIsFound() {
        // Given the boundary as the last line with no trailing LF
        let prefix = "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n"
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}"
        let data = Data((prefix + boundary).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then the offset is at the boundary line start
        XCTAssertEqual(offset, UInt64(prefix.utf8.count))
    }

    func testMarkerSubstringInUserContentIsIgnored() {
        // Given a user message whose content contains the marker bytes as
        // a literal pasted string (false positive for a naive bytes-only
        // search; locator must JSON-confirm type+subtype)
        let pasted = "{\"type\":\"user\",\"message\":{\"content\":\"copy of \\\"subtype\\\":\\\"compact_boundary\\\" from docs\"}}\n"
        let data = Data(pasted.utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then no boundary is reported
        XCTAssertNil(offset)
    }

    func testBoundaryWithPreservedSegmentMetadataIsFound() {
        // Given a boundary line that carries preservedSegment metadata
        let prefix = "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n"
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compactMetadata\":{\"preservedSegment\":{\"messages\":[]}}}\n"
        let data = Data((prefix + boundary).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then the offset is still the boundary line start (caller chooses
        // whether to honor preservedSegment; the locator's job is to find it)
        XCTAssertEqual(offset, UInt64(prefix.utf8.count))
    }

    func testMalformedJSONOnMarkerLineIsSkipped() {
        // Given a line where the marker bytes appear but JSON is broken
        let malformed = "{\"type\":\"system\",\"subtype\":\"compact_boundary\",broken\n"
        let data = Data(malformed.utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then no boundary is reported (we don't trust unparseable lines)
        XCTAssertNil(offset)
    }

    func testBoundaryBeyondOneMegabytePrefixIsStillFound() {
        // Given a 2 MB chunk of user turns followed by a real boundary
        let chunk = String(repeating: "{\"type\":\"user\",\"message\":{\"content\":\"" +
                                       String(repeating: "x", count: 200) +
                                       "\"}}\n",
                           count: 5_000)
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let data = Data((chunk + boundary).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then the offset is at the boundary line start
        XCTAssertEqual(offset, UInt64(chunk.utf8.count))
    }

    func testWrongSubtypeIsIgnored() {
        // Given a system line whose subtype is something else
        let prefix = "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n"
        let line = "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"compact_boundary appears here\"}\n"
        let data = Data((prefix + line).utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then no boundary is reported even though the substring appears
        XCTAssertNil(offset)
    }

    func testWrongTypeIsIgnored() {
        // Given a line with subtype:"compact_boundary" but type other than "system"
        let line = "{\"type\":\"assistant\",\"subtype\":\"compact_boundary\"}\n"
        let data = Data(line.utf8)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(in: data)
        // Then no boundary is reported (claude-code only emits boundaries on system lines)
        XCTAssertNil(offset)
    }

    // MARK: - File-based variant

    private func writeTemp(_ contents: String) -> String {
        let path = NSTemporaryDirectory() + "compact-locator-\(UUID().uuidString).jsonl"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testFileLocatorReturnsNilForEmptyFile() {
        // Given an empty file
        let path = writeTemp("")
        // When we locate on the file
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(at: path, fileSize: 0)
        // Then nil
        XCTAssertNil(offset)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testFileLocatorFindsBoundaryNearEndOfHugeFile() {
        // Given a multi-MB file where the only boundary is near the end —
        // a chunked reverse-scan should find it without reading the whole
        // file. We use 2 MB of filler so the chunk reader has to do at
        // least one seek.
        let chunk = String(repeating: "{\"type\":\"user\",\"message\":{\"content\":\"" +
                                       String(repeating: "x", count: 200) +
                                       "\"}}\n",
                           count: 5_000)
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let tail = "{\"type\":\"user\",\"message\":{\"content\":\"after\"}}\n"
        let path = writeTemp(chunk + boundary + tail)
        let fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(at: path, fileSize: fileSize)
        // Then the offset matches the in-memory scan
        let expected = UInt64(chunk.utf8.count)
        XCTAssertEqual(offset, expected)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testFileLocatorPicksLastOfMultipleBoundariesInFile() {
        // Given a file with two boundaries
        let chunk = "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n"
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}\n"
        let combined = chunk + boundary + chunk + boundary + chunk
        let path = writeTemp(combined)
        let fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(at: path, fileSize: fileSize)
        // Then the offset is the second boundary line start
        let expected = UInt64((chunk + boundary + chunk).utf8.count)
        XCTAssertEqual(offset, expected)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testFileLocatorReturnsNilWhenNoBoundaryInFile() {
        // Given a file with normal content and no boundaries
        let content = String(repeating: "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n", count: 100)
        let path = writeTemp(content)
        let fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        // When we locate
        let offset = CompactBoundaryLocator.findLastBoundaryOffset(at: path, fileSize: fileSize)
        // Then nil
        XCTAssertNil(offset)
        try? FileManager.default.removeItem(atPath: path)
    }
}
