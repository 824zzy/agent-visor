public struct NativeMenuShortcutSnapshot: Equatable, Sendable {
    public let sessionIDs: [String]
    public let positions: [String: Int]

    public init(visibleSessionIDs: [String]) {
        sessionIDs = Array(visibleSessionIDs.prefix(9))
        positions = Dictionary(uniqueKeysWithValues: sessionIDs.enumerated().map {
            ($0.element, $0.offset + 1)
        })
    }

    public func sessionID(at zeroBasedPosition: Int) -> String? {
        sessionIDs.indices.contains(zeroBasedPosition) ? sessionIDs[zeroBasedPosition] : nil
    }
}
