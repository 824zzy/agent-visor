public struct ProcessOutputSnapshot: Equatable, Sendable {
    public let output: String
    public let exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public enum CodexSharedRuntimeSocketPolicy {
    public static func hasConnection(
        processIDs: Set<Int>,
        socketPath: String,
        lsofResult: ProcessOutputSnapshot
    ) -> Bool {
        guard !lsofResult.output.isEmpty else { return false }
        return CodexUnixSocketConnectionMatcher.hasConnection(
            processIDs: processIDs,
            socketPath: socketPath,
            lsofFields: lsofResult.output
        )
    }
}
