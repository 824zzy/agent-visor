import Foundation

public enum SessionActivityDatePolicy {
    public static func merged(current: Date, candidates: [Date?]) -> Date {
        let newestCandidate = candidates.compactMap { $0 }.max()
        guard let newestCandidate, newestCandidate > current else {
            return current
        }
        return newestCandidate
    }
}
