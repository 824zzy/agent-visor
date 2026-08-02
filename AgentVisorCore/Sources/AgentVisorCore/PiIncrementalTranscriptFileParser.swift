import Foundation

public enum PiTranscriptFileChange: Equatable, Sendable {
    case unchanged
    case appended
    case rebuilt
}

public struct PiTranscriptFileParseResult: Equatable, Sendable {
    public let transcript: PiParsedTranscript
    public let change: PiTranscriptFileChange
    /// Exact number of transcript bytes read for this refresh.
    public let bytesRead: Int
    /// Whether at least one complete valid record changed the indexed state.
    public let didChange: Bool

    public init(
        transcript: PiParsedTranscript,
        change: PiTranscriptFileChange,
        bytesRead: Int,
        didChange: Bool
    ) {
        self.transcript = transcript
        self.change = change
        self.bytesRead = bytesRead
        self.didChange = didChange
    }
}

/// Signature-aware, append-only Pi transcript reader.
///
/// The first parse or any incompatible file mutation performs one rebuild.
/// Growth of the same file reads only the captured new byte range, while an
/// identical signature returns the last canonical transcript without opening
/// the file.
public struct PiIncrementalTranscriptFileParser {
    private struct Signature: Equatable {
        let path: String
        let device: UInt64?
        let inode: UInt64?
        let byteCount: UInt64
        let modificationDate: Date

        var identity: String {
            if let device, let inode {
                return "\(device):\(inode)"
            }
            return path
        }
    }

    private var signature: Signature?
    private var accumulator = PiTranscriptAccumulator()
    private var lastTranscript = PiParsedTranscript()

    public init() {}

    public mutating func parse(path: String) throws -> PiTranscriptFileParseResult {
        let current = try Self.signature(path: path)
        let change = readPlan(previous: signature, current: current)

        switch change {
        case .unchanged:
            return PiTranscriptFileParseResult(
                transcript: lastTranscript,
                change: .unchanged,
                bytesRead: 0,
                didChange: false
            )

        case .appended:
            guard let previous = signature else {
                preconditionFailure("Append plan requires a previous signature.")
            }
            let count = current.byteCount - previous.byteCount
            let bytes = try Self.readExactly(
                path: path,
                offset: previous.byteCount,
                count: count
            )
            let acceptedRecords = accumulator.append(bytes)
            let transcript = accumulator.transcript()
            signature = current
            lastTranscript = transcript
            return PiTranscriptFileParseResult(
                transcript: transcript,
                change: .appended,
                bytesRead: bytes.count,
                didChange: acceptedRecords > 0
            )

        case .rebuilt:
            let bytes = try Self.readExactly(
                path: path,
                offset: 0,
                count: current.byteCount
            )
            var rebuilt = PiTranscriptAccumulator()
            let acceptedRecords = rebuilt.append(bytes)
            let transcript = rebuilt.transcript()
            accumulator = rebuilt
            signature = current
            lastTranscript = transcript
            return PiTranscriptFileParseResult(
                transcript: transcript,
                change: .rebuilt,
                bytesRead: bytes.count,
                didChange: acceptedRecords > 0
            )
        }
    }

    private func readPlan(previous: Signature?, current: Signature) -> PiTranscriptFileChange {
        guard let previous else { return .rebuilt }
        guard previous.path == current.path,
              previous.identity == current.identity else {
            return .rebuilt
        }
        if previous == current {
            return .unchanged
        }
        if current.byteCount > previous.byteCount {
            return .appended
        }
        // Truncation and same-size modifications cannot safely reuse the old
        // tree index, even when the file's inode stayed stable.
        return .rebuilt
    }

    private static func signature(path: String) throws -> Signature {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return Signature(
            path: path,
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            byteCount: size.uint64Value,
            modificationDate: modificationDate
        )
    }

    private static func readExactly(
        path: String,
        offset: UInt64,
        count: UInt64
    ) throws -> Data {
        guard count <= UInt64(Int.max) else {
            throw CocoaError(.fileReadTooLarge)
        }
        guard count > 0 else { return Data() }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var result = Data()
        result.reserveCapacity(Int(count))
        var remaining = Int(count)
        while remaining > 0 {
            let requested = min(remaining, 1024 * 1024)
            guard let chunk = try handle.read(upToCount: requested),
                  !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(chunk)
            remaining -= chunk.count
        }
        return result
    }
}
