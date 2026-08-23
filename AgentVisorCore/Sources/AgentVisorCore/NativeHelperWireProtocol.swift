import Foundation

public let nativeHelperProtocolVersion = 1
public let nativeHelperMaximumPayloadBytes = 1_048_576

public enum NativeHelperWireError: Error, Equatable {
    case invalidRequest
    case frameTooLarge
}

public enum NativeHelperPillPhase: String, Codable, Equatable {
    case needsYou = "needs_you"
    case ready
    case working
    case history
}

public struct NativeHelperPill: Codable, Equatable {
    public let id: String
    public let title: String
    public let phase: NativeHelperPillPhase
    public let priority: Int
    public let accessibilityLabel: String

    public init(
        id: String,
        title: String,
        phase: NativeHelperPillPhase,
        priority: Int,
        accessibilityLabel: String
    ) {
        self.id = id
        self.title = title
        self.phase = phase
        self.priority = priority
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct NativeHelperFocusTarget: Codable, Equatable {
    public let pid: Int32
    public let bundleIdentifier: String
    public let windowId: UInt32?

    public init(pid: Int32, bundleIdentifier: String, windowId: UInt32? = nil) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowId = windowId
    }
}

public enum NativeHelperRequest: Equatable {
    case screenTopology(id: String)
    case accessibilityStatus(id: String)
    case presentPills(id: String, pills: [NativeHelperPill])
    case focus(id: String, target: NativeHelperFocusTarget)

    public var id: String {
        switch self {
        case .screenTopology(let id), .accessibilityStatus(let id),
             .presentPills(let id, _), .focus(let id, _):
            id
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= nativeHelperMaximumPayloadBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            throw NativeHelperWireError.invalidRequest
        }

        let requiredKeys: Set<String> = method == "present_pills" || method == "focus"
            ? ["version", "id", "method", "params"]
            : ["version", "id", "method"]
        guard Set(object.keys) == requiredKeys,
              hasStrictNestedFields(method: method, object: object) else {
            throw NativeHelperWireError.invalidRequest
        }

        let wire = try JSONDecoder().decode(WireRequest.self, from: data)
        guard wire.version == nativeHelperProtocolVersion,
              !wire.id.isEmpty, wire.id.count <= 128 else {
            throw NativeHelperWireError.invalidRequest
        }

        switch method {
        case "screen_topology":
            return .screenTopology(id: wire.id)
        case "accessibility_status":
            return .accessibilityStatus(id: wire.id)
        case "present_pills":
            guard let params = wire.params,
                  Set(params.keys) == ["pills"],
                  let pills = params.pills, pills.count <= 64,
                  pills.allSatisfy({ $0.isValid }) else {
                throw NativeHelperWireError.invalidRequest
            }
            return .presentPills(id: wire.id, pills: pills)
        case "focus":
            guard let params = wire.params,
                  Set(params.keys) == ["target"],
                  let target = params.target,
                  target.pid > 0,
                  !target.bundleIdentifier.isEmpty,
                  target.bundleIdentifier.count <= 255 else {
                throw NativeHelperWireError.invalidRequest
            }
            return .focus(id: wire.id, target: target)
        default:
            throw NativeHelperWireError.invalidRequest
        }
    }
}

public struct NativeHelperRectangle: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct NativeHelperScreen: Codable, Equatable {
    public let displayId: UInt32
    public let frame: NativeHelperRectangle
    public let visibleFrame: NativeHelperRectangle
    public let scale: Double
    public let isMain: Bool

    public init(
        displayId: UInt32,
        frame: NativeHelperRectangle,
        visibleFrame: NativeHelperRectangle,
        scale: Double,
        isMain: Bool
    ) {
        self.displayId = displayId
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
    }
}

public enum NativeHelperErrorCode: String, Codable {
    case invalidRequest = "invalid_request"
    case unsupported
    case failed
}

public enum NativeHelperResponse {
    case screenTopology(id: String, screens: [NativeHelperScreen])
    case accessibilityStatus(id: String, trusted: Bool)
    case accepted(id: String)
    case error(id: String, code: NativeHelperErrorCode, message: String)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .screenTopology(let id, let screens):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .screenTopology(screens)
            ))
        case .accessibilityStatus(let id, let trusted):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .accessibilityStatus(trusted)
            ))
        case .accepted(let id):
            return try encoder.encode(SuccessEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: true,
                result: .accepted
            ))
        case .error(let id, let code, let message):
            return try encoder.encode(ErrorEnvelope(
                version: nativeHelperProtocolVersion,
                id: id,
                ok: false,
                error: .init(code: code, message: String(message.prefix(512)))
            ))
        }
    }
}

public enum NativeHelperFrameCodec {
    public static func frame(
        _ payload: Data,
        maxPayloadBytes: Int = nativeHelperMaximumPayloadBytes
    ) throws -> Data {
        guard payload.count <= maxPayloadBytes, payload.count <= Int(UInt32.max) else {
            throw NativeHelperWireError.frameTooLarge
        }
        let size = UInt32(payload.count)
        var framed = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff),
        ])
        framed.append(payload)
        return framed
    }
}

public struct NativeHelperFrameDecoder {
    private var buffer = Data()
    private let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = nativeHelperMaximumPayloadBytes) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public mutating func append<D: DataProtocol>(_ bytes: D) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var payloads: [Data] = []

        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size <= maxPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw NativeHelperWireError.frameTooLarge
            }
            let frameSize = 4 + Int(size)
            guard buffer.count >= frameSize else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: frameSize)
            payloads.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeFirst(frameSize)
        }

        return payloads
    }
}

private func hasStrictNestedFields(method: String, object: [String: Any]) -> Bool {
    switch method {
    case "present_pills":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["pills"],
              let pills = params["pills"] as? [[String: Any]] else { return false }
        let pillKeys: Set<String> = [
            "id", "title", "phase", "priority", "accessibilityLabel",
        ]
        return pills.allSatisfy { Set($0.keys) == pillKeys }
    case "focus":
        guard let params = object["params"] as? [String: Any],
              Set(params.keys) == ["target"],
              let target = params["target"] as? [String: Any] else { return false }
        let keys = Set(target.keys)
        return keys == ["pid", "bundleIdentifier"]
            || keys == ["pid", "bundleIdentifier", "windowId"]
    default:
        return true
    }
}

private struct WireRequest: Decodable {
    let version: Int
    let id: String
    let params: WireParameters?
}

private struct WireParameters: Decodable {
    let pills: [NativeHelperPill]?
    let target: NativeHelperFocusTarget?
    let keys: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        keys = container.allKeys.map(\.stringValue)
        pills = try container.decodeIfPresent([NativeHelperPill].self, forKey: .init("pills"))
        target = try container.decodeIfPresent(NativeHelperFocusTarget.self, forKey: .init("target"))
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension NativeHelperPill {
    var isValid: Bool {
        !id.isEmpty && id.count <= 128
            && !title.isEmpty && title.count <= 256
            && !accessibilityLabel.isEmpty && accessibilityLabel.count <= 512
    }
}

private struct SuccessEnvelope: Encodable {
    let version: Int
    let id: String
    let ok: Bool
    let result: ResultBody
}

private enum ResultBody: Encodable {
    case screenTopology([NativeHelperScreen])
    case accessibilityStatus(Bool)
    case accepted

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case .screenTopology(let screens):
            try container.encode("screen_topology", forKey: .init("type"))
            try container.encode(screens, forKey: .init("screens"))
        case .accessibilityStatus(let trusted):
            try container.encode("accessibility_status", forKey: .init("type"))
            try container.encode(trusted, forKey: .init("trusted"))
        case .accepted:
            try container.encode("accepted", forKey: .init("type"))
        }
    }
}

private struct ErrorEnvelope: Encodable {
    struct Body: Encodable {
        let code: NativeHelperErrorCode
        let message: String
    }

    let version: Int
    let id: String
    let ok: Bool
    let error: Body
}
