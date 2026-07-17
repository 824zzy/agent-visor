import Foundation

public struct CodexRolloutFileSignature: Equatable, Sendable {
    public let path: String
    public let byteCount: Int64

    public init(path: String, byteCount: Int64) {
        self.path = path
        self.byteCount = byteCount
    }
}
