import CryptoKit
import Foundation

public enum CodexWebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public enum CodexWebSocketStreamEvent: Equatable, Sendable {
    case message(Data)
    case ping(Data)
    case pong(Data)
    case close(Data)
}

public enum CodexWebSocketCodecError: Error, Equatable, Sendable {
    case invalidHandshake
    case invalidAccept
    case reservedBitsSet
    case unsupportedOpcode(UInt8)
    case unexpectedContinuation
    case unfinishedFragment
    case fragmentedControlFrame
    case oversizedControlFrame
    case maskedServerFrame
    case payloadTooLarge
}

public enum CodexWebSocketCodec {
    public static func handshakeRequest(
        path: String,
        host: String,
        key: String
    ) -> Data {
        Data(
            """
            GET \(path) HTTP/1.1\r
            Host: \(host)\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Key: \(key)\r
            Sec-WebSocket-Version: 13\r
            \r

            """.utf8
        )
    }

    public static func validateHandshakeResponse(
        _ response: Data,
        key: String
    ) throws {
        guard let text = String(data: response, encoding: .utf8) else {
            throw CodexWebSocketCodecError.invalidHandshake
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first,
              status.hasPrefix("HTTP/1.1 101 ") || status == "HTTP/1.1 101" else {
            throw CodexWebSocketCodecError.invalidHandshake
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let digest = Insecure.SHA1.hash(
            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        )
        let expected = Data(digest).base64EncodedString()
        guard headers["sec-websocket-accept"] == expected else {
            throw CodexWebSocketCodecError.invalidAccept
        }
        let connectionTokens = headers["connection"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? []
        guard headers["upgrade"]?.lowercased() == "websocket",
              connectionTokens.contains("upgrade"),
              headers["sec-websocket-extensions"] == nil,
              headers["sec-websocket-protocol"] == nil else {
            throw CodexWebSocketCodecError.invalidHandshake
        }
    }

    public static func clientFrame(
        payload: Data,
        opcode: CodexWebSocketOpcode,
        maskKey: [UInt8]
    ) -> Data {
        precondition(maskKey.count == 4)
        var frame = Data([0x80 | opcode.rawValue])
        appendLength(payload.count, masked: true, to: &frame)
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: payload.enumerated().map { index, byte in
            byte ^ maskKey[index % maskKey.count]
        })
        return frame
    }

    private static func appendLength(
        _ length: Int,
        masked: Bool,
        to frame: inout Data
    ) {
        let maskBit: UInt8 = masked ? 0x80 : 0
        if length <= 125 {
            frame.append(maskBit | UInt8(length))
        } else if length <= Int(UInt16.max) {
            frame.append(maskBit | 126)
            let value = UInt16(length).bigEndian
            withUnsafeBytes(of: value) { frame.append(contentsOf: $0) }
        } else {
            frame.append(maskBit | 127)
            let value = UInt64(length).bigEndian
            withUnsafeBytes(of: value) { frame.append(contentsOf: $0) }
        }
    }
}

public struct CodexWebSocketStreamDecoder: Sendable {
    private var buffer = Data()
    private var fragmentedPayload: Data?
    private let maximumPayloadLength: Int

    public init(maximumPayloadLength: Int = 64 * 1024 * 1024) {
        self.maximumPayloadLength = maximumPayloadLength
    }

    public mutating func append<DataChunk: DataProtocol>(
        _ chunk: DataChunk
    ) throws -> [CodexWebSocketStreamEvent] {
        buffer.append(contentsOf: chunk)
        var events: [CodexWebSocketStreamEvent] = []
        while let frame = try nextFrame() {
            switch frame.opcode {
            case .text, .binary:
                guard fragmentedPayload == nil else {
                    throw CodexWebSocketCodecError.unfinishedFragment
                }
                if frame.isFinal {
                    events.append(.message(frame.payload))
                } else {
                    fragmentedPayload = frame.payload
                }
            case .continuation:
                guard var payload = fragmentedPayload else {
                    throw CodexWebSocketCodecError.unexpectedContinuation
                }
                guard payload.count <= maximumPayloadLength - frame.payload.count else {
                    throw CodexWebSocketCodecError.payloadTooLarge
                }
                payload.append(frame.payload)
                if frame.isFinal {
                    fragmentedPayload = nil
                    events.append(.message(payload))
                } else {
                    fragmentedPayload = payload
                }
            case .ping:
                events.append(.ping(frame.payload))
            case .pong:
                events.append(.pong(frame.payload))
            case .close:
                events.append(.close(frame.payload))
            }
        }
        return events
    }

    private mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(min(buffer.count, 14)))
        let first = bytes[0]
        guard first & 0x70 == 0 else {
            throw CodexWebSocketCodecError.reservedBitsSet
        }
        let isFinal = first & 0x80 != 0
        guard let opcode = CodexWebSocketOpcode(rawValue: first & 0x0F) else {
            throw CodexWebSocketCodecError.unsupportedOpcode(first & 0x0F)
        }

        let second = bytes[1]
        let isMasked = second & 0x80 != 0
        guard !isMasked else {
            throw CodexWebSocketCodecError.maskedServerFrame
        }
        var payloadLength = UInt64(second & 0x7F)
        var cursor = 2
        if payloadLength == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            payloadLength = UInt64(readUInt16(at: cursor))
            cursor += 2
        } else if payloadLength == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            payloadLength = readUInt64(at: cursor)
            cursor += 8
        }

        guard payloadLength <= UInt64(maximumPayloadLength) else {
            throw CodexWebSocketCodecError.payloadTooLarge
        }
        let controlFrame = opcode.rawValue >= CodexWebSocketOpcode.close.rawValue
        if controlFrame, !isFinal {
            throw CodexWebSocketCodecError.fragmentedControlFrame
        }
        if controlFrame, payloadLength > 125 {
            throw CodexWebSocketCodecError.oversizedControlFrame
        }

        guard payloadLength <= UInt64(Int.max) else {
            throw CodexWebSocketCodecError.payloadTooLarge
        }
        let payloadCount = Int(payloadLength)
        guard buffer.count >= cursor + payloadCount else { return nil }
        let payload = Data(buffer[cursor..<(cursor + payloadCount)])
        buffer.removeSubrange(buffer.startIndex..<(cursor + payloadCount))

        return Frame(isFinal: isFinal, opcode: opcode, payload: payload)
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        buffer[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        buffer[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private struct Frame {
        let isFinal: Bool
        let opcode: CodexWebSocketOpcode
        let payload: Data
    }
}
