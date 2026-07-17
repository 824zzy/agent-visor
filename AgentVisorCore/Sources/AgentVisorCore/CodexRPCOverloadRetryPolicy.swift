public enum CodexRPCOverloadRetryPolicy {
    public static func delayNanoseconds(
        errorCode: Int,
        retryAttempt: Int
    ) -> UInt64? {
        guard errorCode == -32001 else { return nil }
        let delays: [UInt64] = [
            100_000_000,
            250_000_000,
            500_000_000,
        ]
        guard delays.indices.contains(retryAttempt) else { return nil }
        return delays[retryAttempt]
    }
}
